// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMorpho} from "./interfaces/IMorpho.sol";

import "./Base.sol";

/// @dev When a trove goes underwater, the redemption path underflows and funds can only be pulled
///      in kind by liquidating it: the liquidation repayment refills the Lender's idle liquidity,
///      which the liquidator pulls back out with shares in the same transaction
contract BadDebtTests is Base {

    // Tokens
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    // wstETH/WETH Morpho oracle
    address public constant MORPHO_ORACLE = 0xbD60A6770b27E084E8617335ddE769241B0e71D8;

    function setUp() public override {
        Base.setUp();

        // Stay within Morpho's flashloanable WETH liquidity
        maxFuzzAmount = 10_000 ether;
    }

    // ============================================================================================
    // Deployment hooks
    // ============================================================================================

    /// @dev Deploy a local v2 wstETH/WETH market
    function _deployLender() internal override returns (address) {
        address _priceOracle = deployCode("lib/flex-contracts/out/morpho_oracle.vy/morpho_oracle.json", abi.encode(MORPHO_ORACLE, WETH, WSTETH));
        return deployFlexMarket(WETH, WSTETH, _priceOracle, 0.1e18); // 0.1 WETH minimum debt
    }

    // ============================================================================================
    // Tests
    // ============================================================================================

    // A vault depositor exits in kind with no capital: flashloan the repayment, liquidate the trove,
    // then withdraw against the idle liquidity the liquidation just created to repay the flashloan
    function test_badDebt_holderExitsInKind(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        (IVault _vault, uint256 _troveId, uint256 _price) = _setUpBadDebt(_amount, 0.91e18);
        ITroveManager _tm = ITroveManager(address(LENDER.TROVE_MANAGER()));

        // The redemption path is bricked, freeing beyond idle underflows on the underwater trove
        vm.prank(management);
        vm.expectRevert();
        strategy.forceFreeFunds(type(uint256).max, 0);

        // The user hands their vault shares to the exiter contract
        BadDebtExiter _exiter = new BadDebtExiter();
        uint256 _shares = _vault.balanceOf(user);
        vm.prank(user);
        ERC20(address(_vault)).transfer(address(_exiter), _shares);

        // Flashloan the trove's full debt, an upper bound on the liquidation repayment
        ITroveManager.Trove memory _trove = _tm.troves(_troveId);
        _exiter.exit(_tm, _vault, _troveId, _tm.get_trove_debt_after_interest(_troveId));
        uint256 _paid = _exiter.paid();
        uint256 _collateral = _exiter.collateral();

        // All the collateral was taken, at a discount to its (dropped) oracle value
        assertEq(_collateral, _trove.collateral, "E0");
        assertEq(ERC20(WSTETH).balanceOf(address(_exiter)), _collateral, "E1");
        assertGt(_collateral * _price / 1e36, _paid, "E2");

        // The flashloan was repaid without any capital of the exiter's own, only dust remains
        assertLe(asset.balanceOf(address(_exiter)), 2, "E3");
        assertApproxEqAbs(_shares - _vault.balanceOf(address(_exiter)), _paid, 4, "E4");

        // The trove is gone and the bad debt was socialized on the Lender atomically
        assertEq(uint256(_tm.troves(_troveId).status), uint256(ITroveManager.Status.liquidated), "E5");
        assertLt(LENDER.convertToAssets(WAD), WAD, "E6");

        // The strategy's own price per share is stale until its next report
        assertEq(strategy.pricePerShare(), WAD, "E7");
    }

    // A curator holding no shares exits in kind: liquidate the trove, buy the vault's strategy
    // shares at par with `buy_debt`, then redeem them against the idle the liquidation created.
    // The flashloan bridges the `buy_debt` leg, so only the repayment itself needs own capital
    function test_badDebt_curatorExitsViaBuyDebt(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        (IVault _vault, uint256 _troveId, uint256 _price) = _setUpBadDebt(_amount, 0.91e18);
        ITroveManager _tm = ITroveManager(address(LENDER.TROVE_MANAGER()));

        // The curator contract holds no vault or strategy shares, only working capital
        BadDebtCurator _curator = new BadDebtCurator();
        _vault.set_role(address(_curator), 16383);
        ITroveManager.Trove memory _trove = _tm.troves(_troveId);
        uint256 _debt = _tm.get_trove_debt_after_interest(_troveId);
        airdrop(asset, address(_curator), _debt);

        // Flashloan the trove's full debt, an upper bound on the liquidation repayment
        _curator.exit(_tm, _vault, strategy, _troveId, _debt);
        uint256 _paid = _curator.paid();
        uint256 _collateral = _curator.collateral();

        // All the collateral was taken, at a discount to its (dropped) oracle value
        assertEq(_collateral, _trove.collateral, "E0");
        assertEq(ERC20(WSTETH).balanceOf(address(_curator)), _collateral, "E1");
        assertGt(_collateral * _price / 1e36, _paid, "E2");

        // Net spend is the liquidation repayment only
        assertApproxEqAbs(_debt - asset.balanceOf(address(_curator)), _paid, 2, "E3");

        // The vault swapped strategy debt for idle at par
        assertEq(asset.balanceOf(address(_vault)), _paid, "E4");
        assertEq(_vault.totalIdle(), _paid, "E5");
        assertApproxEqAbs(strategy.balanceOf(address(_vault)), _amount - _paid, 2, "E6");

        // The trove is gone and the bad debt was socialized on the Lender atomically
        assertEq(uint256(_tm.troves(_troveId).status), uint256(ITroveManager.Status.liquidated), "E7");
        assertLt(LENDER.convertToAssets(WAD), WAD, "E8");
    }

    // Collateral repricing that stays inside the buffer (CR above 105% == 100% + max liquidation
    // fee): the liquidation repays debt in full, the fee comes out of the borrower's buffer, and
    // no loss reaches the lender
    function test_badDebt_lossInsideBuffer_lenderWhole(
        uint256 _amount,
        uint256 _targetCR
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _targetCR = bound(_targetCR, 1.055e18, 1.095e18);

        (IVault _vault, uint256 _troveId, uint256 _price) = _setUpBadDebt(_amount, _targetCR);
        ITroveManager _tm = ITroveManager(address(LENDER.TROVE_MANAGER()));
        uint256 _debtBefore = _tm.get_trove_debt_after_interest(_troveId);

        // The user hands their vault shares to the exiter contract
        BadDebtExiter _exiter = new BadDebtExiter();
        uint256 _shares = _vault.balanceOf(user);
        vm.prank(user);
        ERC20(address(_vault)).transfer(address(_exiter), _shares);

        // Liquidate, partially, bringing the trove back to the safe CR
        _exiter.exit(_tm, _vault, _troveId, _debtBefore);
        uint256 _paid = _exiter.paid();
        uint256 _collateral = _exiter.collateral();

        // The repayment is covered by its collateral equivalent plus a fee, and the flashloan repaid
        assertGt(_paid, 0, "E0");
        assertGt(_collateral * _price / 1e36, _paid, "E1");
        assertEq(ERC20(WSTETH).balanceOf(address(_exiter)), _collateral, "E2");
        assertLe(asset.balanceOf(address(_exiter)), 2, "E3");

        // The trove survives with reduced debt
        assertEq(uint256(_tm.troves(_troveId).status), uint256(ITroveManager.Status.active), "E4");
        assertLt(_tm.get_trove_debt_after_interest(_troveId), _debtBefore, "E5");

        // No loss reaches the Lender or the strategy
        vm.prank(LENDER.keeper());
        LENDER.report();
        assertGe(LENDER.convertToAssets(WAD), WAD, "E6");
        vm.prank(keeper);
        (, uint256 _loss) = strategy.report();
        assertEq(_loss, 0, "E7");
    }

    // Once the repricing eats through the buffer (CR below 105%), the liquidation can no longer
    // repay the full debt and the shortfall is socialized to the lender
    function test_badDebt_lossBeyondBuffer_lenderLoss(
        uint256 _amount,
        uint256 _targetCR
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);
        _targetCR = bound(_targetCR, 1e18, 1.03e18);

        (IVault _vault, uint256 _troveId,) = _setUpBadDebt(_amount, _targetCR);
        ITroveManager _tm = ITroveManager(address(LENDER.TROVE_MANAGER()));
        uint256 _debt = _tm.get_trove_debt_after_interest(_troveId);

        // The user hands their vault shares to the exiter contract
        BadDebtExiter _exiter = new BadDebtExiter();
        uint256 _shares = _vault.balanceOf(user);
        vm.prank(user);
        ERC20(address(_vault)).transfer(address(_exiter), _shares);

        // Liquidate, fully
        _exiter.exit(_tm, _vault, _troveId, _debt);

        // The repayment falls short of the debt and the Lender is marked down atomically
        assertLt(_exiter.paid(), _debt, "E0");
        assertEq(uint256(_tm.troves(_troveId).status), uint256(ITroveManager.Status.liquidated), "E1");
        assertLt(LENDER.convertToAssets(WAD), WAD, "E2");
    }

    // ============================================================================================
    // Helpers
    // ============================================================================================

    /// @dev Allocate `_amount` of vault deposits, borrow half of it, then reprice the collateral
    ///      so the trove sits at the target CR
    function _setUpBadDebt(
        uint256 _amount,
        uint256 _targetCR
    ) internal returns (IVault _vault, uint256 _troveId, uint256 _price) {
        _vault = _setUpVault(_amount);
        _troveId = openTrove(address(77), _amount / 2);

        ITroveManager _tm = ITroveManager(address(LENDER.TROVE_MANAGER()));
        _price = _targetCR * _tm.get_trove_debt_after_interest(_troveId) * WAD / _tm.troves(_troveId).collateral;
        vm.mockCall(_tm.price_oracle(), abi.encodeWithSignature("get_price()"), abi.encode(_price));
    }

}

/// @dev Exits a vault position in kind with no capital of its own: flashloans the liquidation
///      repayment, liquidates the underwater trove keeping all its collateral, then repays the
///      flashloan out of the idle liquidity the liquidation just created using its vault shares
contract BadDebtExiter {

    uint256 public paid;
    uint256 public collateral;

    IMorpho public constant MORPHO = IMorpho(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);

    function exit(
        ITroveManager _tm,
        IVault _vault,
        uint256 _troveId,
        uint256 _flashAmount
    ) external {
        MORPHO.flashLoan(_tm.borrow_token(), _flashAmount, abi.encode(_tm, _vault, _troveId));
    }

    function onMorphoFlashLoan(
        uint256 _assets,
        bytes calldata _data
    ) external {
        require(msg.sender == address(MORPHO), "!morpho");
        (ITroveManager _tm, IVault _vault, uint256 _troveId) = abi.decode(_data, (ITroveManager, IVault, uint256));
        ERC20 _borrowToken = ERC20(_tm.borrow_token());

        // Liquidate the trove, taking all its collateral at a discount
        _borrowToken.approve(address(_tm), type(uint256).max);
        collateral = _tm.liquidate_trove(_troveId, type(uint256).max, address(this), "");
        paid = _assets - _borrowToken.balanceOf(address(this));

        // Pull the repayment back out of the Lender with our vault shares, grossed up for rounding dust
        _vault.withdraw(paid + 2, address(this), address(this), 1);

        // Let Morpho pull the repayment
        _borrowToken.approve(address(MORPHO), _assets);
    }

}

/// @dev Exits a vault it holds no shares of: flashloans to liquidate the underwater trove keeping
///      all its collateral, buys the vault's strategy shares at par with `buy_debt`, then redeems
///      them against the idle liquidity the liquidation just created to repay the flashloan
contract BadDebtCurator {

    uint256 public paid;
    uint256 public collateral;

    IMorpho public constant MORPHO = IMorpho(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);

    function exit(
        ITroveManager _tm,
        IVault _vault,
        IStrategy _strategy,
        uint256 _troveId,
        uint256 _flashAmount
    ) external {
        MORPHO.flashLoan(_tm.borrow_token(), _flashAmount, abi.encode(_tm, _vault, _strategy, _troveId));
    }

    function onMorphoFlashLoan(
        uint256 _assets,
        bytes calldata _data
    ) external {
        require(msg.sender == address(MORPHO), "!morpho");
        (ITroveManager _tm, IVault _vault, IStrategy _strategy, uint256 _troveId) = abi.decode(_data, (ITroveManager, IVault, IStrategy, uint256));
        ERC20 _borrowToken = ERC20(_tm.borrow_token());
        uint256 _balanceBefore = _borrowToken.balanceOf(address(this));

        // Liquidate the trove, taking all its collateral at a discount
        _borrowToken.approve(address(_tm), type(uint256).max);
        collateral = _tm.liquidate_trove(_troveId, type(uint256).max, address(this), "");
        paid = _balanceBefore - _borrowToken.balanceOf(address(this));

        // Buy the vault's strategy shares at par with the repayment amount
        _borrowToken.approve(address(_vault), paid);
        _vault.buy_debt(address(_strategy), paid);

        // Redeem them against the idle liquidity the liquidation just created
        _strategy.redeem(_strategy.balanceOf(address(this)), address(this), address(this));

        // Let Morpho pull the repayment
        _borrowToken.approve(address(MORPHO), _assets);
    }

}
