// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMorphoOracleFactory} from "../interfaces/IMorphoOracleFactory.sol";

import {InfinifiFlexLenderStrategy} from "../../src/integrations/InfinifiStrategy.sol";

import {IInfiniFiGateway} from "../interfaces/IInfiniFiGateway.sol";

import "./CooldownBase.sol";

contract InfinifiStrategyTests is CooldownStrategyTests {

    using stdStorage for StdStorage;

    InfinifiFlexLenderStrategy public infinifiStrategy;

    // Tokens
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant SIUSD = 0xDBDC1Ef57537E34680B898E1FEBD3D68c7389bCB;
    address public constant IUSD = 0x48f9e38f3070AD8945DFEae3FA70987722E3D89c;

    // siUSD/USDC Morpho oracle factory
    address public constant MORPHO_ORACLE_FACTORY = 0x3A7bB36Ee3f3eE32A60e9f2b33c1e5f2E83ad766;

    // ============================================================================================
    // Deployment hooks
    // ============================================================================================

    /// @dev Deploy a local v2 siUSD/USDC market
    function _deployLender() internal override returns (address) {
        // siUSD/USDC price oracle (vault conversion only, iUSD assumed $1)
        address _morphoOracle = IMorphoOracleFactory(MORPHO_ORACLE_FACTORY)
            .createMorphoChainlinkOracleV2(
                SIUSD, // baseVault: siUSD
                1e18, // baseVaultConversionSample
                address(0), // baseFeed1
                address(0), // baseFeed2
                18, // baseTokenDecimals: iUSD
                address(0), // quoteVault
                1, // quoteVaultConversionSample
                address(0), // quoteFeed1
                address(0), // quoteFeed2
                6, // quoteTokenDecimals: USDC
                bytes32(0) // salt
            );
        address _priceOracle = deployCode("lib/flex-contracts/out/morpho_oracle.vy/morpho_oracle.json", abi.encode(_morphoOracle, USDC, SIUSD));

        return deployFlexMarket(USDC, SIUSD, _priceOracle, 500e6); // 500 USDC minimum debt
    }

    /// @dev Deploy the InfiniFi strategy wrapping the local market's Lender
    function _deployStrategy() internal override returns (IStrategy) {
        infinifiStrategy = new InfinifiFlexLenderStrategy(address(LENDER), address(exitRouter), "Flex siUSD/USDC Lender");
        cooldownStrategy = ICooldownStrategy(address(infinifiStrategy));
        IStrategy _strategy = IStrategy(address(infinifiStrategy));
        _strategy.setKeeper(keeper);
        _strategy.setPerformanceFeeRecipient(performanceFeeRecipient);
        _strategy.setPendingManagement(management);
        return _strategy;
    }

    // ============================================================================================
    // Tests
    // ============================================================================================

    function test_setup() public view {
        assertEq(address(infinifiStrategy.COLLATERAL()), SIUSD, "E0");
        assertEq(address(infinifiStrategy.IUSD()), IUSD, "E1");
        assertEq(infinifiStrategy.pendingRedemptions(), 0, "E2");
        assertEq(address(asset), USDC, "E3");
        assertEq(address(LENDER.TROVE_MANAGER().collateral_token()), SIUSD, "E4");
    }

    function test_constructor_wrongCollateral_reverts() public {
        // The live yvUSD/USDC Lender's collateral does not unwrap to iUSD
        address _yvusdLender = 0xA967FcDb8a2bEF38caaB6131169c9D45be550Db0;
        vm.expectRevert("!iusd");
        new InfinifiFlexLenderStrategy(_yvusdLender, address(exitRouter), "nope");
    }

    function test_initiateCooldown(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        uint256 _loose = _freeInKind(_amount);

        // Unwind the loose siUSD through InfiniFi
        vm.prank(management);
        (uint256 _assetsOut, uint256 _pending) = infinifiStrategy.initiateCooldown(type(uint256).max, 0);

        // All the collateral was unwound, into instant assets and/or a queued redemption
        assertGt(_loose, 0, "E0");
        assertEq(ERC20(SIUSD).balanceOf(address(strategy)), 0, "E1");
        assertApproxEqRel(_assetsOut + _pending, _amount, 1e16, "E2"); // 1%
        assertEq(infinifiStrategy.pendingRedemptions(), _pending, "E3");
    }

    function test_initiateCooldown_revertsWhileAlreadyPending(
        uint256 _pending
    ) public {
        _pending = bound(_pending, 1, type(uint128).max);
        stdstore.target(address(infinifiStrategy)).sig("pendingRedemptions()").checked_write(_pending);

        vm.prank(management);
        vm.expectRevert("!pending");
        infinifiStrategy.initiateCooldown(type(uint256).max, 0);
    }

    function test_initiateCooldown_minInstant(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        _freeInKind(_amount);

        // Measure the instant fill, then rewind
        uint256 _snapshot = vm.snapshotState();
        vm.prank(management);
        (uint256 _assetsOut,) = infinifiStrategy.initiateCooldown(type(uint256).max, 0);
        vm.revertToState(_snapshot);

        // Asking for more than the instant fill reverts
        vm.prank(management);
        vm.expectRevert("shrekt");
        infinifiStrategy.initiateCooldown(type(uint256).max, _assetsOut + 1);

        // Asking for exactly the instant fill passes
        vm.prank(management);
        (uint256 _secondAssetsOut,) = infinifiStrategy.initiateCooldown(type(uint256).max, _assetsOut);
        assertEq(_secondAssetsOut, _assetsOut, "E0");
    }

    function test_initiateCooldown_wrongCaller(
        address _wrongCaller
    ) public {
        vm.assume(_wrongCaller != management);
        vm.prank(_wrongCaller);
        vm.expectRevert("!management");
        infinifiStrategy.initiateCooldown(1, 0);
    }

    function test_claimCooldown(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        _freeInKind(_amount);

        vm.prank(management);
        (, uint256 _pending) = infinifiStrategy.initiateCooldown(type(uint256).max, 0);

        // Nothing was queued -- nothing to claim
        if (_pending == 0) {
            vm.prank(management);
            vm.expectRevert("!claim");
            infinifiStrategy.claimCooldown();
            return;
        }

        // Fund InfiniFi's redemption queue by minting new iUSD
        address _minter = address(88);
        airdrop(asset, _minter, _pending * 2);
        vm.startPrank(_minter);
        asset.approve(address(infinifiStrategy.GATEWAY()), _pending * 2);
        IInfiniFiGateway(address(infinifiStrategy.GATEWAY())).mint(_minter, _pending * 2);
        vm.stopPrank();

        // Claim the queued redemption
        uint256 _balanceBefore = asset.balanceOf(address(strategy));
        vm.prank(management);
        uint256 _claimed = infinifiStrategy.claimCooldown();

        assertEq(asset.balanceOf(address(strategy)), _balanceBefore + _claimed, "E0");
        assertApproxEqRel(_claimed, _pending, 1e16, "E1"); // 1%
        assertEq(infinifiStrategy.pendingRedemptions(), 0, "E2");
    }

    function test_claimCooldown_wrongCaller(
        address _wrongCaller
    ) public {
        vm.assume(_wrongCaller != management);
        vm.prank(_wrongCaller);
        vm.expectRevert("!management");
        infinifiStrategy.claimCooldown();
    }

}
