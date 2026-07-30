// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IVault} from "../script/interfaces/IVault.sol";
import {IVaultFactory} from "../script/interfaces/IVaultFactory.sol";

import {FlexExitRouter} from "../src/periphery/ExitRouter.sol";

import "./Base.sol";

contract StrategyTests is Base {

    using stdStorage for StdStorage;

    // 3.0.4 Vault Factory
    IVaultFactory public constant VAULT_FACTORY = IVaultFactory(0x770D0d1Fb036483Ed4AbB6d53c1C88fb277D812F);

    function setUp() public override {
        Base.setUp();
    }

    function test_setupStrategyOK() public view {
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

    function test_forceFreeFunds_maxUint_lowSharePrice(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Drop the Lender's share price below one, so converting a max amount overflows
        _dropLenderSharePrice();

        // Freeing everything still works, as the amount is never converted
        vm.prank(management);
        strategy.forceFreeFunds(type(uint256).max, 0);

        assertEq(LENDER.balanceOf(address(strategy)), 0, "E0");
        assertGt(asset.balanceOf(address(strategy)), 0, "E1");
    }

    function test_emergencyWithdraw_maxUint_lowSharePrice(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Drop the Lender's share price below one, so converting a max amount overflows
        _dropLenderSharePrice();

        // Withdrawing everything still works, as the amount is never converted
        vm.startPrank(management);
        strategy.shutdownStrategy();
        strategy.emergencyWithdraw(type(uint256).max);
        vm.stopPrank();

        assertEq(LENDER.balanceOf(address(strategy)), 0, "E0");
        assertGt(asset.balanceOf(address(strategy)), 0, "E1");
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

    // A settling auction's proceeds are not counted yet, so reports and further force frees are blocked
    // until it settles
    function test_forceFreeFunds_settlingAuction_blocks(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        mintAndDepositIntoStrategy(strategy, user, _amount);

        // Drain the Lender's idle so the force free kicks an auction
        openTrove(address(77), _amount);

        IDutchDesk _dutchDesk = IDutchDesk(ITroveManager(address(LENDER.TROVE_MANAGER())).dutch_desk());
        IAuction _auction = IAuction(_dutchDesk.auction());
        uint256 _auctionId = _dutchDesk.nonce();

        vm.prank(management);
        strategy.forceFreeFunds(_amount, 0);
        assertEq(strategy.pendingAuctionId(), _auctionId, "E0");

        // Reporting is blocked while the auction settles
        vm.prank(keeper);
        vm.expectRevert("!auction");
        strategy.report();

        // So is freeing more funds
        vm.prank(management);
        vm.expectRevert("!auction");
        strategy.forceFreeFunds(_amount, 0);

        // Once the auction is taken, reporting works again. Allow a loss, since the auction settles
        // below the oracle price by the decay it took to get filled
        takeAuction(_auctionId, _auction);
        vm.prank(management);
        strategy.setLossLimitRatio(MAX_BPS - 1);
        vm.prank(keeper);
        strategy.report();
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

    // ============================================================================================
    // Exit router
    // ============================================================================================

    /// @dev Halve the Lender's total assets, putting its share price below one. Converting a max amount
    ///      then overflows, since it scales by `totalSupply / totalAssets`
    function _dropLenderSharePrice() internal {
        stdstore.target(address(LENDER)).sig("totalAssets()").checked_write(LENDER.totalSupply() / 2);

        vm.expectRevert();
        LENDER.previewWithdraw(type(uint256).max);
    }

    /// @dev Deploy a V3 vault holding the strategy, and allocate `_amount` of `user` deposits to it
    function _setUpVault(
        uint256 _amount
    ) internal returns (IVault _vault) {
        _vault = IVault(VAULT_FACTORY.deploy_new_vault(address(asset), "Flex USDC yVault", "yvFlexUSDC", address(this), 7 days));
        _vault.set_role(address(this), 16383);
        _vault.set_deposit_limit(type(uint256).max);
        _vault.add_strategy(address(strategy));
        _vault.update_max_debt_for_strategy(address(strategy), type(uint256).max);
        vm.prank(management);
        strategy.setAllowed(address(_vault), true);

        // Deposit into the vault and allocate everything to the strategy
        airdrop(asset, user, _amount);
        vm.startPrank(user);
        asset.approve(address(_vault), _amount);
        _vault.deposit(_amount, user);
        vm.stopPrank();
        _vault.update_debt(address(strategy), _amount);
    }

    function test_setProceedsReceiver_notRouter_reverts(
        address _caller,
        address _receiver
    ) public {
        vm.assume(_caller != address(exitRouter));

        vm.prank(_caller);
        vm.expectRevert("!exitRouter");
        strategy.setProceedsReceiver(_receiver);
    }

    function test_exitRouter_redeem(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        IVault _vault = _setUpVault(_amount);

        // Drain the Lender's idle completely
        openTrove(address(77), asset.balanceOf(address(LENDER)));

        IDutchDesk _dutchDesk = IDutchDesk(ITroveManager(address(LENDER.TROVE_MANAGER())).dutch_desk());
        IAuction _auction = IAuction(_dutchDesk.auction());
        uint256 _nonceBefore = _dutchDesk.nonce();

        // Without the router the withdrawal is capped by the Lender's idle, which is now zero
        uint256 _shares = _vault.balanceOf(user);
        vm.prank(user);
        vm.expectRevert();
        _vault.redeem(_shares, user, user, MAX_BPS);

        // Through the router the full position is withdrawable
        IStrategy[] memory _strategies = new IStrategy[](1);
        _strategies[0] = strategy;
        vm.startPrank(user);
        ERC20(address(_vault)).approve(address(exitRouter), _shares);
        exitRouter.redeem(address(_vault), _shares, user, user, MAX_BPS, _strategies);
        vm.stopPrank();

        // The vault position is closed and an auction was kicked with the user as receiver
        assertEq(_vault.balanceOf(user), 0, "E0");
        assertEq(_dutchDesk.nonce(), _nonceBefore + 1, "E1");
        uint256 _auctionId = _nonceBefore;
        assertEq(_auction.auctions(_auctionId).receiver, user, "E2");

        // Take the auction -- the proceeds flow directly to the user
        uint256 _balanceBefore = asset.balanceOf(user);
        takeAuction(_auctionId, _auction);
        assertApproxEqRel(asset.balanceOf(user) - _balanceBefore, _amount, 1e16, "E3"); // 1%
    }

    function test_exitRouter_redeem_clearsReceiver(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        IVault _vault = _setUpVault(_amount);

        // Redeem half through the router
        uint256 _shares = _vault.balanceOf(user) / 2;
        IStrategy[] memory _strategies = new IStrategy[](1);
        _strategies[0] = strategy;
        vm.startPrank(user);
        ERC20(address(_vault)).approve(address(exitRouter), _shares);
        exitRouter.redeem(address(_vault), _shares, user, user, MAX_BPS, _strategies);
        vm.stopPrank();

        // The router cleared the receiver before returning, so the limit is idle-bound again
        assertLt(strategy.availableWithdrawLimit(user), type(uint256).max, "E0");
    }

    // The receiver can only be set by the router, which burns the setter's shares in the same call, so a
    // debt manager cannot redirect the strategy's position to itself
    function test_exitRouter_debtManagerCannotDivert(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        IVault _vault = _setUpVault(_amount);

        // The debt manager cannot arm the strategy
        address _debtManager = address(this);
        vm.prank(_debtManager);
        vm.expectRevert("!exitRouter");
        strategy.setProceedsReceiver(_debtManager);

        // So pulling the whole position can only move the Lender's idle, which is what the strategy
        // holds anyway -- nothing is diverted and the vault keeps the value
        uint256 _managerBefore = asset.balanceOf(_debtManager);
        _vault.update_debt(address(strategy), 0);

        assertEq(asset.balanceOf(_debtManager), _managerBefore, "E0");
        assertApproxEqAbs(asset.balanceOf(address(_vault)), _amount, 1, "E1");
    }

    // The router clears the receiver before returning, so a debt manager cannot arm the strategy with a
    // dust redemption and then consume the armed receiver later in the same transaction
    function test_exitRouter_sequencedDivert_reverts(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        IVault _vault = _setUpVault(_amount);

        // Give the attacker a dust position and the debt manager role
        SequencedExitAttacker _attacker = new SequencedExitAttacker();
        uint256 _dust = _amount / 100;
        vm.prank(user);
        ERC20(address(_vault)).transfer(address(_attacker), _dust);
        _vault.set_role(address(_attacker), 16_383);

        _attacker.attack(exitRouter, _vault, strategy, _dust);

        // The attacker only got its own dust position, the rest of the position went to the vault
        assertApproxEqRel(asset.balanceOf(address(_attacker)), _dust, 1e16, "E0"); // 1%
        assertApproxEqRel(asset.balanceOf(address(_vault)), _amount - _dust, 1e16, "E1"); // 1%
    }

    function test_exitRouter_redeem_withoutAllowance_reverts(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        IVault _vault = _setUpVault(_amount);

        IStrategy[] memory _strategies = new IStrategy[](1);
        _strategies[0] = strategy;

        // A third party cannot redeem the user's shares without an allowance
        uint256 _shares = _vault.balanceOf(user);
        address _thirdParty = address(777);
        vm.prank(_thirdParty);
        vm.expectRevert("insufficient allowance");
        exitRouter.redeem(address(_vault), _shares, _thirdParty, user, MAX_BPS, _strategies);
    }

    function test_exitRouter_redeem_delegated(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        IVault _vault = _setUpVault(_amount);

        IStrategy[] memory _strategies = new IStrategy[](1);
        _strategies[0] = strategy;

        // The user approves the router, so a third party can exit on their behalf
        uint256 _shares = _vault.balanceOf(user);
        vm.prank(user);
        ERC20(address(_vault)).approve(address(exitRouter), _shares);

        uint256 _balanceBefore = asset.balanceOf(user);
        vm.prank(address(777));
        exitRouter.redeem(address(_vault), _shares, user, user, MAX_BPS, _strategies);

        assertEq(_vault.balanceOf(user), 0, "E0");
        assertApproxEqRel(asset.balanceOf(user) - _balanceBefore, _amount, 1e16, "E1"); // 1%
    }

}

/// @dev Arms a strategy through the router with a dust position, then tries to consume the armed
///      receiver by pulling the strategy's whole position in the same transaction
contract SequencedExitAttacker {

    function attack(
        FlexExitRouter _router,
        IVault _vault,
        IStrategy _strategy,
        uint256 _shares
    ) external {
        // Redeem our own dust position through the router, which arms the strategy
        ERC20(address(_vault)).approve(address(_router), _shares);
        IStrategy[] memory _strategies = new IStrategy[](1);
        _strategies[0] = _strategy;
        _router.redeem(address(_vault), _shares, address(this), address(this), 10_000, _strategies);

        // Then try to divert the rest of the position to ourselves
        _vault.update_debt(address(_strategy), 0);
    }

}
