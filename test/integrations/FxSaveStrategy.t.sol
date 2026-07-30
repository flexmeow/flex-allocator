// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {FxSaveFlexLenderStrategy} from "../../src/integrations/FxSaveStrategy.sol";
import {IFxUSDBasePool} from "../../src/interfaces/IFxUSDBasePool.sol";

import "./CooldownBase.sol";

contract FxSaveStrategyTests is CooldownStrategyTests {

    FxSaveFlexLenderStrategy public fxSaveStrategy;

    // Tokens
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant FXUSD = 0x085780639CC2cACd35E474e71f4d000e2405d8f6;
    address public constant FXSAVE = 0x7743e50F534a7f9F1791DdE7dCD89F7783Eefc39;
    address public constant FXBASE = 0x65C9A641afCEB9C0E6034e558A319488FA0FA3be;

    // fxSAVE/USDC Morpho oracle
    address public constant MORPHO_ORACLE = 0x16931Dcc888754Ae780B153598376a6474DE4440;

    // ============================================================================================
    // Deployment hooks
    // ============================================================================================

    /// @dev Deploy a local v2 fxSAVE/USDC market
    function _deployLender() internal override returns (address) {
        address _priceOracle = deployCode("lib/flex-contracts/out/morpho_oracle.vy/morpho_oracle.json", abi.encode(MORPHO_ORACLE, USDC, FXSAVE));
        return deployFlexMarket(USDC, FXSAVE, _priceOracle, 500e6); // 500 USDC minimum debt
    }

    /// @dev Deploy the fxSAVE strategy wrapping the local market's Lender
    function _deployStrategy() internal override returns (IStrategy) {
        fxSaveStrategy = new FxSaveFlexLenderStrategy(address(LENDER), address(exitRouter), "Flex fxSAVE/USDC Lender");
        cooldownStrategy = ICooldownStrategy(address(fxSaveStrategy));
        IStrategy _strategy = IStrategy(address(fxSaveStrategy));
        _strategy.setKeeper(keeper);
        _strategy.setPerformanceFeeRecipient(performanceFeeRecipient);
        _strategy.setPendingManagement(management);
        return _strategy;
    }

    // ============================================================================================
    // Tests
    // ============================================================================================

    function test_setup() public view {
        assertEq(address(fxSaveStrategy.COLLATERAL()), FXSAVE, "E0");
        assertEq(address(fxSaveStrategy.FXBASE()), FXBASE, "E1");
        assertEq(fxSaveStrategy.pendingRedemptions(), 0, "E2");
        assertEq(address(asset), USDC, "E3");
        assertEq(address(LENDER.TROVE_MANAGER().collateral_token()), FXSAVE, "E4");
    }

    function test_constructor_wrongCollateral_reverts() public {
        // The live yvUSD/USDC Lender's collateral does not unwrap to fxBASE
        address _yvusdLender = 0xA967FcDb8a2bEF38caaB6131169c9D45be550Db0;
        vm.expectRevert("!fxbase");
        new FxSaveFlexLenderStrategy(_yvusdLender, address(exitRouter), "nope");
    }

    function test_initiateCooldown_resetsUnlockClock(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        uint256 _loose = _freeInKind(_amount);
        uint256 _cooldown = IFxUSDBasePool(FXBASE).redeemCoolDownPeriod();

        // Queue half, wait out the cooldown, then queue the rest -- the whole amount locks again
        vm.startPrank(management);
        uint256 _firstPending = fxSaveStrategy.initiateCooldown(_loose / 2);
        skip(_cooldown);
        fxSaveStrategy.initiateCooldown(type(uint256).max);
        vm.stopPrank();

        assertGt(_firstPending, 0, "E0");
        assertGt(fxSaveStrategy.pendingRedemptions(), _firstPending, "E1");
        assertEq(ERC20(FXSAVE).balanceOf(address(strategy)), 0, "E2");

        // The queued amount is worth ~ the freed amount
        assertApproxEqRel(fxSaveStrategy.pendingRedemptions(), _amount, 1e16, "E3"); // 1%

        // The second request reset the unlock clock, so the claim reverts
        vm.prank(management);
        vm.expectRevert();
        fxSaveStrategy.claimCooldown();
    }

    function test_claimCooldown(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        _freeInKind(_amount);

        // Queue the whole balance
        vm.prank(management);
        uint256 _pending = fxSaveStrategy.initiateCooldown(type(uint256).max);
        assertGt(_pending, 0, "E0");

        // Wait out the cooldown and claim, receiving a mix of USDC and fxUSD
        skip(IFxUSDBasePool(FXBASE).redeemCoolDownPeriod());
        vm.prank(management);
        (uint256 _assetsOut, uint256 _fxusdOut) = fxSaveStrategy.claimCooldown();

        // The claim is worth ~ the queued amount, valuing fxUSD at $1
        assertApproxEqRel(_assetsOut + _fxusdOut / 1e12, _pending, 1e16, "E1"); // 1%
        assertEq(fxSaveStrategy.pendingRedemptions(), 0, "E2");

        // Swap any fxUSD leg back to the asset
        if (_fxusdOut > 0) {
            uint256 _balanceBefore = asset.balanceOf(address(strategy));
            vm.prank(management);
            uint256 _swapped = fxSaveStrategy.swapFxUsd(type(uint256).max, 0);
            assertEq(asset.balanceOf(address(strategy)), _balanceBefore + _swapped, "E3");
            assertApproxEqRel(_swapped, _fxusdOut / 1e12, 2e16, "E4"); // 2%
            assertEq(ERC20(FXUSD).balanceOf(address(strategy)), 0, "E5");
        }
    }

    function test_swapFxUsd(
        uint256 _amount
    ) public {
        _amount = bound(_amount, 100e18, 100_000e18); // 100 to 100k fxUSD

        // Airdrop fxUSD to the strategy and swap it
        airdrop(ERC20(FXUSD), address(strategy), _amount);
        uint256 _balanceBefore = asset.balanceOf(address(strategy));
        vm.prank(management);
        uint256 _swapped = fxSaveStrategy.swapFxUsd(type(uint256).max, 0);

        assertEq(asset.balanceOf(address(strategy)), _balanceBefore + _swapped, "E0");
        assertApproxEqRel(_swapped, _amount / 1e12, 2e16, "E1"); // 2%
        assertEq(ERC20(FXUSD).balanceOf(address(strategy)), 0, "E2");
    }

    function test_claimCooldown_wrongCaller(
        address _wrongCaller
    ) public {
        vm.assume(_wrongCaller != management);
        vm.prank(_wrongCaller);
        vm.expectRevert("!management");
        fxSaveStrategy.claimCooldown();
    }

    function test_swapFxUsd_wrongCaller(
        address _wrongCaller
    ) public {
        vm.assume(_wrongCaller != management);
        vm.prank(_wrongCaller);
        vm.expectRevert("!management");
        fxSaveStrategy.swapFxUsd(1, 0);
    }

}
