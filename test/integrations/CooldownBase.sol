// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ICooldownStrategy} from "../../src/interfaces/ICooldownStrategy.sol";

import "../Base.sol";

abstract contract CooldownStrategyTests is Base {

    using stdStorage for StdStorage;

    // The strategy under test, set in `_deployStrategy`
    ICooldownStrategy public cooldownStrategy;

    // ============================================================================================
    // Shared tests
    // ============================================================================================

    function test_operation(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);
        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn interest
        openAndCloseTrove(_amount, 1 days);

        // Report profit
        vm.prank(keeper);
        (uint256 _profit, uint256 _loss) = strategy.report();
        assertGt(_profit, 0, "!profit");
        assertEq(_loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

        // Withdraw all funds
        uint256 _balanceBefore = asset.balanceOf(user);
        vm.prank(user);
        strategy.redeem(_amount, user, user);
        assertGe(asset.balanceOf(user), _balanceBefore + _amount, "!final balance");
    }

    function test_forceFreeFunds_takeInKind(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        uint256 _loose = _freeInKind(_amount);

        // The strategy holds the collateral in kind, worth ~ the freed amount
        assertGt(_loose, 0, "E0");
        uint256 _price = IPriceOracle(ITroveManager(address(LENDER.TROVE_MANAGER())).price_oracle()).get_price();
        assertApproxEqRel(_loose * _price / 1e36, _amount, 1e16, "E1"); // 1%

        // No asset was spent on the take -- the payment netted out
        assertEq(LENDER.balanceOf(address(strategy)), 0, "E2");
    }

    function test_report_blockedWhilePending(
        uint256 _pending
    ) public {
        _pending = bound(_pending, 1, type(uint128).max);
        stdstore.target(address(cooldownStrategy)).sig("pendingRedemptions()").checked_write(_pending);

        vm.prank(keeper);
        vm.expectRevert("!cooldown");
        strategy.report();
    }

    function test_zeroPendingRedemptions(
        uint256 _pending
    ) public {
        _pending = bound(_pending, 1, type(uint128).max);
        stdstore.target(address(cooldownStrategy)).sig("pendingRedemptions()").checked_write(_pending);

        vm.prank(management);
        cooldownStrategy.zeroPendingRedemptions();
        assertEq(cooldownStrategy.pendingRedemptions(), 0, "E0");
    }

    function test_zeroPendingRedemptions_wrongCaller(
        address _wrongCaller
    ) public {
        vm.assume(_wrongCaller != management);
        vm.prank(_wrongCaller);
        vm.expectRevert("!management");
        cooldownStrategy.zeroPendingRedemptions();
    }

    // ============================================================================================
    // Helpers
    // ============================================================================================

    /// @dev Deposit, drain the Lender's idle, force-free with an in-kind take. Returns the loose collateral
    function _freeInKind(
        uint256 _amount
    ) internal returns (uint256) {
        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Drain the Lender's idle completely
        openTrove(address(77), asset.balanceOf(address(LENDER)));

        // Force-free with an in-kind take: kick + self-take at the oracle price atomically
        vm.prank(management);
        cooldownStrategy.forceFreeFundsInKind(_amount, 0);

        return _collateral().balanceOf(address(strategy));
    }

    /// @dev The market's collateral token
    function _collateral() internal view returns (ERC20) {
        return ERC20(ITroveManager(address(LENDER.TROVE_MANAGER())).collateral_token());
    }

}
