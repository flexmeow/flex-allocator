// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "./Base.sol";

contract StrategyTests is Base {

    function setUp() public override {
        Base.setUp();
    }

    function test_setupStrategyOK() public {
        assertEq(strategy.asset(), address(asset));
        assertEq(strategy.management(), management);
        assertEq(strategy.performanceFeeRecipient(), performanceFeeRecipient);
        assertEq(strategy.keeper(), keeper);
    }

    function test_operation(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        openAndCloseTrove(_amount, 1 days);

        // Report profit
        vm.prank(strategy.keeper());
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGe(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(asset.balanceOf(user), balanceBefore + _amount, "!final balance");
    }

    function test_profitableReport(
        uint256 _amount,
        uint16 _profitFactor
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        _profitFactor = uint16(bound(uint256(_profitFactor), 10, MAX_BPS / 10));

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        openAndCloseTrove(_amount, 1 days);

        // Simulate yield by airdropping the asset directly to the strategy
        uint256 toAirdrop = (_amount * _profitFactor) / MAX_BPS;
        airdrop(asset, address(strategy), toAirdrop);

        // Report profit
        vm.prank(strategy.keeper());
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGe(profit, toAirdrop, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());
        // 1023 230330
        // 1026 090120

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(asset.balanceOf(user), balanceBefore + _amount, "!final balance");
    }

    function test_profitableReport_withFees(
        uint256 _amount,
        uint16 _profitFactor
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);
        _profitFactor = uint16(bound(uint256(_profitFactor), 10, MAX_BPS / 10));

        // Set perf fee to 10%
        vm.prank(management);
        strategy.setPerformanceFee(1_000);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        openAndCloseTrove(_amount, 10 days);

        // Report profit
        vm.prank(strategy.keeper());
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGe(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        skip(strategy.profitMaxUnlockTime());

        // Get the expected fee
        uint256 expectedShares = (profit * 1_000) / MAX_BPS;

        assertEq(strategy.balanceOf(performanceFeeRecipient), expectedShares);

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(asset.balanceOf(user), balanceBefore + _amount, "!final balance");

        vm.prank(performanceFeeRecipient);
        strategy.redeem(expectedShares, performanceFeeRecipient, performanceFeeRecipient);

        checkStrategyTotals(strategy, 0, 0, 0);

        assertGe(asset.balanceOf(performanceFeeRecipient), expectedShares, "!perf fee out");
    }

    function test_shutdownCanWithdraw(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        openAndCloseTrove(_amount, 1 days);

        // Report profit
        vm.prank(strategy.keeper());
        strategy.report();

        skip(strategy.profitMaxUnlockTime());

        // Shutdown the strategy
        vm.prank(management);
        strategy.shutdownStrategy();

        assertGe(strategy.totalAssets(), _amount, "!totalAssets");

        // Make sure we can still withdraw the full amount
        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(asset.balanceOf(user), balanceBefore + _amount, "!final balance");
    }

    function test_emergencyWithdraw_maxUint(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        openAndCloseTrove(_amount, 1 days);

        // Shutdown the strategy
        vm.prank(management);
        strategy.shutdownStrategy();

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // should be able to pass uint 256 max and not revert.
        vm.prank(management);
        strategy.emergencyWithdraw(type(uint256).max);

        // Make sure we can still withdraw the full amount
        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(asset.balanceOf(user), balanceBefore + _amount, "!final balance");
    }

    function test_forceFreeFunds_idleOnly(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        IDutchDesk _dutchDesk = IDutchDesk(ITroveManager(address(LENDER.TROVE_MANAGER())).dutch_desk());
        uint256 _nonceBefore = _dutchDesk.nonce();

        vm.prank(management);
        uint256 _freed = strategy.forceFreeFunds(_amount, _amount - 1);

        // No auction was kicked - the Lender covered it from idle
        assertEq(_dutchDesk.nonce(), _nonceBefore, "auction kicked");

        // Strategy got the asset atomically and burned Lender shares
        assertApproxEqAbs(_freed, _amount, 1, "E0");
        assertEq(asset.balanceOf(address(strategy)), _freed, "E1");
        assertEq(LENDER.balanceOf(address(strategy)), 0, "E2");
    }

    function test_forceFreeFunds_kicksAuction(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Drain the Lender's idle by borrowing roughly all of it
        openTrove(address(77), _amount);
        assertLt(asset.balanceOf(address(LENDER)), _amount, "lender still has idle");

        IDutchDesk _dutchDesk = IDutchDesk(ITroveManager(address(LENDER.TROVE_MANAGER())).dutch_desk());
        IAuction _auction = IAuction(_dutchDesk.auction());
        uint256 _nonceBefore = _dutchDesk.nonce();

        // Force-free the full amount - shortfall kicks an auction (no min-out enforced, async delivery)
        vm.prank(management);
        strategy.forceFreeFunds(_amount, 0);

        assertEq(_dutchDesk.nonce(), _nonceBefore + 1, "E0");

        uint256 _auctionId = _nonceBefore;
        assertTrue(_auction.is_active(_auctionId), "E1");
        assertGt(_auction.get_available_amount(_auctionId), 0, "E2");

        // Liquidator takes the auction at the market price; proceeds go to the strategy (auction receiver)
        takeAuction(_auctionId, _auction);

        assertEq(_auction.get_available_amount(_auctionId), 0, "E3");
        assertFalse(_auction.is_active(_auctionId), "E4");
        assertApproxEqAbs(asset.balanceOf(address(strategy)), _amount, 10, "E5");
    }

    function test_forceFreeFunds_slippage_reverts(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Drain the Lender's idle so the atomic delivery falls short of `_amount`
        openTrove(address(77), _amount);

        // `_minOut = _amount` enforces an atomic delivery the Lender can't satisfy
        vm.prank(management);
        vm.expectRevert("shrekt");
        strategy.forceFreeFunds(_amount, _amount);
    }

    function test_deployIdleFunds(
        uint256 _idle
    ) public {
        _idle = bound(_idle, minFuzzAmount, maxFuzzAmount);

        airdrop(asset, address(strategy), _idle);

        uint256 _expectedLenderShares = LENDER.convertToShares(_idle);

        vm.prank(management);
        uint256 _deployed = strategy.deployIdleFunds(_idle);

        assertEq(_deployed, _idle, "E0");
        assertEq(asset.balanceOf(address(strategy)), 0, "E1");
        assertEq(LENDER.balanceOf(address(strategy)), _expectedLenderShares, "E2");
    }

    function test_deployIdleFunds_capsByIdleBalance(
        uint256 _idle,
        uint256 _request
    ) public {
        _idle = bound(_idle, minFuzzAmount, maxFuzzAmount);
        _request = bound(_request, _idle + 1, type(uint256).max);

        airdrop(asset, address(strategy), _idle);

        vm.prank(management);
        uint256 _deployed = strategy.deployIdleFunds(_request);

        assertEq(_deployed, _idle, "E0");
        assertEq(asset.balanceOf(address(strategy)), 0, "E1");
    }

    function test_deployIdleFunds_capsByLenderLimit(
        uint256 _idle,
        uint256 _lenderHeadroom
    ) public {
        _idle = bound(_idle, minFuzzAmount + 1, maxFuzzAmount);
        _lenderHeadroom = bound(_lenderHeadroom, minFuzzAmount, _idle - 1);

        airdrop(asset, address(strategy), _idle);

        vm.startPrank(LENDER.management());
        LENDER.setDepositLimit(LENDER.totalAssets() + _lenderHeadroom);
        vm.stopPrank();

        uint256 _expected = LENDER.availableDepositLimit(address(strategy));
        if (_expected > _idle) _expected = _idle;

        vm.prank(management);
        uint256 _deployed = strategy.deployIdleFunds(_idle);

        assertEq(_deployed, _expected, "E0");
        assertEq(asset.balanceOf(address(strategy)), _idle - _expected, "E1");
    }

    function test_setOpen_gating(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        address _depositor = address(77);

        airdrop(asset, _depositor, _amount);

        vm.startPrank(_depositor);
        asset.approve(address(strategy), _amount);
        vm.expectRevert("ERC4626: deposit more than max");
        strategy.deposit(_amount, _depositor);
        vm.stopPrank();

        vm.prank(management);
        strategy.setOpen(true);

        vm.prank(_depositor);
        strategy.deposit(_amount, _depositor);

        assertGt(strategy.balanceOf(_depositor), 0, "E0");
    }

    function test_setAllowed_gating(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        address _depositor = address(77);
        address _stranger = address(78);

        airdrop(asset, _depositor, _amount);
        airdrop(asset, _stranger, _amount);

        vm.prank(management);
        strategy.setAllowed(_depositor, true);

        vm.startPrank(_depositor);
        asset.approve(address(strategy), _amount);
        strategy.deposit(_amount, _depositor);
        vm.stopPrank();

        vm.startPrank(_stranger);
        asset.approve(address(strategy), _amount);
        vm.expectRevert("ERC4626: deposit more than max");
        strategy.deposit(_amount, _stranger);
        vm.stopPrank();
    }

    function test_availableWithdrawLimit_capsByLenderIdle(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Drain the Lender's idle by opening a trove
        openTrove(address(77), _amount);

        uint256 _lenderIdle = asset.balanceOf(address(LENDER));
        assertLt(_lenderIdle, _amount, "lender still has idle");
        assertEq(strategy.availableWithdrawLimit(user), _lenderIdle, "E0");
    }

    function test_setOpen_wrongCaller(
        address _wrongCaller,
        bool _isOpen
    ) public {
        vm.assume(_wrongCaller != management);

        vm.prank(_wrongCaller);
        vm.expectRevert("!management");
        strategy.setOpen(_isOpen);
    }

    function test_setAllowed_wrongCaller(
        address _wrongCaller,
        address _address,
        bool _isAllowed
    ) public {
        vm.assume(_wrongCaller != management);

        vm.prank(_wrongCaller);
        vm.expectRevert("!management");
        strategy.setAllowed(_address, _isAllowed);
    }

    function test_forceFreeFunds_wrongCaller(
        address _wrongCaller,
        uint256 _amount,
        uint256 _minOut
    ) public {
        vm.assume(_wrongCaller != management);

        vm.prank(_wrongCaller);
        vm.expectRevert("!management");
        strategy.forceFreeFunds(_amount, _minOut);
    }

    function test_deployIdleFunds_wrongCaller(
        address _wrongCaller,
        uint256 _amount
    ) public {
        vm.assume(_wrongCaller != management);

        vm.prank(_wrongCaller);
        vm.expectRevert("!management");
        strategy.deployIdleFunds(_amount);
    }

}
