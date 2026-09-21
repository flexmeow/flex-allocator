// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {LockedYvusdFlexLenderStrategy} from "../../src/integrations/LockedYvusdStrategy.sol";
import {ILockedVault} from "../../src/interfaces/ILockedVault.sol";

import "./CooldownBase.sol";

contract LockedYvusdStrategyTests is CooldownStrategyTests {

    LockedYvusdFlexLenderStrategy public lockedYvusdStrategy;

    // Tokens
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant YVUSD = 0x696d02Db93291651ED510704c9b286841d506987;
    address public constant LOCKED_YVUSD = 0xAaaFEa48472f77563961Cdb53291DEDfB46F9040;

    function setUp() public override {
        Base.setUp();
    }

    // ============================================================================================
    // Deployment hooks
    // ============================================================================================

    /// @dev Deploy a local v2 Locked yvUSD/USDC market
    function _deployLender() internal override returns (address) {
        address _priceOracle = address(new LockedYvusdOracle());
        return deployFlexMarket(USDC, LOCKED_YVUSD, _priceOracle, 500e6); // 500 USDC minimum debt
    }

    /// @dev Deploy the Locked yvUSD strategy wrapping the local market's Lender
    function _deployStrategy() internal override returns (IStrategy) {
        lockedYvusdStrategy = new LockedYvusdFlexLenderStrategy(address(LENDER), address(exitRouter), "Flex Locked yvUSD/USDC Lender");
        cooldownStrategy = ICooldownStrategy(address(lockedYvusdStrategy));
        IStrategy _strategy = IStrategy(address(lockedYvusdStrategy));
        _strategy.setKeeper(keeper);
        _strategy.setPerformanceFeeRecipient(performanceFeeRecipient);
        _strategy.setPendingManagement(management);
        return _strategy;
    }

    // ============================================================================================
    // Tests
    // ============================================================================================

    function test_setup() public view {
        assertEq(address(lockedYvusdStrategy.COLLATERAL()), LOCKED_YVUSD, "E0");
        assertEq(address(lockedYvusdStrategy.YVUSD()), YVUSD, "E1");
        assertEq(lockedYvusdStrategy.pendingRedemptions(), 0, "E2");
        assertEq(address(asset), USDC, "E3");
        assertEq(address(LENDER.TROVE_MANAGER().collateral_token()), LOCKED_YVUSD, "E4");
    }

    function test_constructor_wrongCollateral_reverts() public {
        // The live yvUSD/USDC Lender's collateral does not unwrap to yvUSD
        address _yvusdLender = 0xA967FcDb8a2bEF38caaB6131169c9D45be550Db0;
        vm.expectRevert("!yvusd");
        new LockedYvusdFlexLenderStrategy(_yvusdLender, address(exitRouter), "nope");
    }

    function test_constructor_startingPriceBuffer_reverts() public {
        // A market with a starting price buffer cannot be wrapped
        startingPriceBuffer = 1e18 + 1e15; // 100.1%
        address _oracle = ITroveManager(address(LENDER.TROVE_MANAGER())).price_oracle();
        address _lender = deployFlexMarket(USDC, LOCKED_YVUSD, _oracle, 500e6);
        vm.expectRevert("!buffer");
        new LockedYvusdFlexLenderStrategy(_lender, address(exitRouter), "nope");
    }

    function test_initiateCooldown(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        uint256 _loose = _freeInKind(_amount);

        // Start cooling all the loose Locked yvUSD
        vm.prank(management);
        uint256 _pending = lockedYvusdStrategy.initiateCooldown(type(uint256).max);

        // The shares stay put while cooling, and their asset value is pending
        assertGt(_loose, 0, "E0");
        assertEq(ERC20(LOCKED_YVUSD).balanceOf(address(strategy)), _loose, "E1");
        (,, uint256 _cooling) = ILockedVault(LOCKED_YVUSD).getCooldownStatus(address(strategy));
        assertEq(_cooling, _loose, "E2");
        assertEq(_pending, IERC4626(YVUSD).convertToAssets(IERC4626(LOCKED_YVUSD).convertToAssets(_loose)), "E3");
        assertEq(lockedYvusdStrategy.pendingRedemptions(), _pending, "E4");
        assertApproxEqRel(_pending, _amount, 1e16, "E5"); // 1%

        // Reports are blocked until the cooldown is claimed
        vm.prank(keeper);
        vm.expectRevert("!cooldown");
        strategy.report();
    }

    function test_initiateCooldown_replaces(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        uint256 _loose = _freeInKind(_amount);

        // A second cooldown replaces the first, on the vault and in the accounting
        vm.startPrank(management);
        uint256 _firstPending = lockedYvusdStrategy.initiateCooldown(_loose / 2);
        uint256 _pending = lockedYvusdStrategy.initiateCooldown(type(uint256).max);
        vm.stopPrank();

        (,, uint256 _cooling) = ILockedVault(LOCKED_YVUSD).getCooldownStatus(address(strategy));
        assertEq(_cooling, _loose, "E0");
        assertGt(_pending, _firstPending, "E1");
        assertEq(lockedYvusdStrategy.pendingRedemptions(), _pending, "E2");
    }

    function test_initiateCooldown_replacesPartial(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        uint256 _loose = _freeInKind(_amount);
        uint256 _pendingBefore = lockedYvusdStrategy.pendingRedemptions();

        // Starting the same partial cooldown twice puts the first half back loose, nothing goes missing
        vm.startPrank(management);
        lockedYvusdStrategy.initiateCooldown(_loose / 2);
        uint256 _pending = lockedYvusdStrategy.initiateCooldown(_loose / 2);
        vm.stopPrank();

        assertEq(lockedYvusdStrategy.pendingRedemptions(), _pendingBefore, "E0");

        // Wait out the cooldown and claim the cooling half
        skip(ILockedVault(LOCKED_YVUSD).cooldownDuration() + 1);
        vm.prank(management);
        uint256 _claimed = lockedYvusdStrategy.claimCooldown(0);
        assertApproxEqRel(_claimed, _pending, 1e15, "E1"); // 0.1%

        // The other half is still pending and blocks reports
        assertEq(lockedYvusdStrategy.takenInKind(), ERC20(LOCKED_YVUSD).balanceOf(address(strategy)), "E2");
        assertApproxEqRel(lockedYvusdStrategy.pendingRedemptions(), _pending, 1e15, "E3"); // 0.1%
        vm.prank(keeper);
        vm.expectRevert("!cooldown");
        strategy.report();
    }

    function test_claimCooldown(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        _freeInKind(_amount);

        vm.prank(management);
        uint256 _pending = lockedYvusdStrategy.initiateCooldown(type(uint256).max);

        // Wait out the cooldown
        skip(ILockedVault(LOCKED_YVUSD).cooldownDuration() + 1);

        // Claim, unwinding all the way to the asset
        uint256 _balanceBefore = asset.balanceOf(address(strategy));
        vm.prank(management);
        uint256 _claimed = lockedYvusdStrategy.claimCooldown(0);

        assertEq(asset.balanceOf(address(strategy)), _balanceBefore + _claimed, "E0");
        assertApproxEqRel(_claimed, _pending, 1e15, "E1"); // 0.1%
        assertLe(ERC20(LOCKED_YVUSD).balanceOf(address(strategy)), 1, "E2"); // `maxRedeem` rounds down a wei
        assertEq(ERC20(YVUSD).balanceOf(address(strategy)), 0, "E3");
        assertLe(lockedYvusdStrategy.pendingRedemptions(), 1e3, "E4"); // dust

        // Reporting works again. Allow a loss, since the in-kind take settled below par
        vm.prank(management);
        strategy.setLossLimitRatio(MAX_BPS - 1);
        vm.prank(keeper);
        strategy.report();
    }

    function test_claimCooldown_beforeCooldown_reverts(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        _freeInKind(_amount);

        vm.startPrank(management);
        lockedYvusdStrategy.initiateCooldown(type(uint256).max);

        // Nothing is redeemable before the cooldown ends
        vm.expectRevert("ZERO_ASSETS");
        lockedYvusdStrategy.claimCooldown(0);
        vm.stopPrank();
    }

    function test_claimCooldown_afterWindow_reverts(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        _freeInKind(_amount);

        ILockedVault _lockedYvusd = ILockedVault(LOCKED_YVUSD);
        uint256 _cooldownDuration = _lockedYvusd.cooldownDuration();
        uint256 _withdrawalWindow = _lockedYvusd.withdrawalWindow();

        vm.prank(management);
        lockedYvusdStrategy.initiateCooldown(type(uint256).max);

        // Missing the window means nothing is redeemable
        skip(_cooldownDuration + _withdrawalWindow + 1);
        vm.prank(management);
        vm.expectRevert("ZERO_ASSETS");
        lockedYvusdStrategy.claimCooldown(0);

        // Starting over works
        vm.prank(management);
        lockedYvusdStrategy.initiateCooldown(type(uint256).max);
        skip(_cooldownDuration + 1);
        vm.prank(management);
        uint256 _claimed = lockedYvusdStrategy.claimCooldown(0);
        assertGt(_claimed, 0, "E0");
    }

    function test_claimCooldown_slippage_reverts(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        _freeInKind(_amount);

        vm.prank(management);
        lockedYvusdStrategy.initiateCooldown(type(uint256).max);
        skip(ILockedVault(LOCKED_YVUSD).cooldownDuration() + 1);

        vm.prank(management);
        vm.expectRevert("shrekt");
        lockedYvusdStrategy.claimCooldown(type(uint256).max);
    }

    function test_initiateCooldown_wrongCaller(
        address _wrongCaller
    ) public {
        vm.assume(_wrongCaller != management);
        vm.prank(_wrongCaller);
        vm.expectRevert("!management");
        lockedYvusdStrategy.initiateCooldown(1);
    }

    function test_claimCooldown_wrongCaller(
        address _wrongCaller
    ) public {
        vm.assume(_wrongCaller != management);
        vm.prank(_wrongCaller);
        vm.expectRevert("!management");
        lockedYvusdStrategy.claimCooldown(0);
    }

}

/// @dev Prices Locked yvUSD in USDC through both vault exchange rates, in the market's
///      10^(36 + usdc_decimals - locked_yvusd_decimals) format
contract LockedYvusdOracle {

    IERC4626 internal constant _YVUSD = IERC4626(0x696d02Db93291651ED510704c9b286841d506987);
    IERC4626 internal constant _LOCKED_YVUSD = IERC4626(0xAaaFEa48472f77563961Cdb53291DEDfB46F9040);

    function get_price() external view returns (uint256) {
        return _price() * 1e30;
    }

    function get_price(
        bool _scaled
    ) external view returns (uint256) {
        return _scaled ? _price() * 1e30 : _price() * 1e12;
    }

    /// @dev USDC per Locked yvUSD share, both 6 decimals
    function _price() internal view returns (uint256) {
        return _YVUSD.convertToAssets(_LOCKED_YVUSD.convertToAssets(1e6));
    }

}
