// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ILender} from "../src/interfaces/ILender.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";

import {IAuction} from "./interfaces/IAuction.sol";
import {IDutchDesk} from "./interfaces/IDutchDesk.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {ITroveManager} from "./interfaces/ITroveManager.sol";

import {DeployStrategyFactory} from "../script/DeployStrategyFactory.s.sol";

import "forge-std/Test.sol";

contract Base is DeployStrategyFactory, Test {

    // Contracts
    ERC20 public asset;
    IStrategy public strategy;
    ILender public constant LENDER = ILender(0xA967FcDb8a2bEF38caaB6131169c9D45be550Db0);

    // Roles
    address public user = address(1);
    address public management = address(420);
    address public keeper = address(69);
    address public performanceFeeRecipient = address(42069);

    // Fuzz bounds
    uint256 public maxFuzzAmount = 1_000_000 ether;
    uint256 public minFuzzAmount = 1_000 ether;

    uint256 public MAX_BPS = 10_000;
    uint256 public WAD = 1e18;
    uint256 public ASSET_PRECISION;

    function setUp() public virtual {
        // Notify deployment script that this is a test
        isTest = true;

        // Create fork
        uint256 _blockNumber = 25_043_786; // cache state for faster tests
        vm.selectFork(vm.createFork(vm.envString("ETH_RPC_URL"), _blockNumber));

        // Deploy the StrategyFactory
        run();

        // Deploy a Strategy wrapping the on-chain Lender
        strategy =
            IStrategy(strategyFactory.deploy(LENDER.asset(), address(LENDER), management, keeper, performanceFeeRecipient, "Flex Lender Strategy"));
        asset = ERC20(strategy.asset());
        ASSET_PRECISION = 10 ** asset.decimals();

        vm.label(address(LENDER), "Lender");
        vm.label(address(strategy), "Strategy");
        vm.label(address(asset), "Asset");

        // Accept management and set allowed
        vm.startPrank(management);
        strategy.acceptManagement();
        strategy.setAllowed(user, true);
        vm.stopPrank();

        // Make sure the Lender's deposit limit doesn't constrain the fuzz range
        vm.prank(LENDER.management());
        LENDER.setDepositLimit(type(uint256).max);

        // Adjust fuzzing limits based on asset decimals
        if (asset.decimals() < 18) {
            uint256 _decimalsDiff = 18 - asset.decimals();
            maxFuzzAmount = maxFuzzAmount / (10 ** _decimalsDiff);
            minFuzzAmount = minFuzzAmount / (10 ** _decimalsDiff);
        }
    }

    // ============================================================================================
    // Helpers
    // ============================================================================================

    function airdrop(
        ERC20 _asset,
        address _to,
        uint256 _amount
    ) public {
        uint256 _balanceBefore = _asset.balanceOf(_to);
        deal(address(_asset), _to, _balanceBefore + _amount);
    }

    function depositIntoStrategy(
        IStrategy _strategy,
        address _user,
        uint256 _amount
    ) public {
        vm.prank(_user);
        asset.approve(address(_strategy), _amount);

        vm.prank(_user);
        _strategy.deposit(_amount, _user);
    }

    function mintAndDepositIntoStrategy(
        IStrategy _strategy,
        address _user,
        uint256 _amount
    ) public {
        airdrop(asset, _user, _amount);
        depositIntoStrategy(_strategy, _user, _amount);
    }

    function openTrove(
        address _borrower,
        uint256 _borrowAmount
    ) public returns (uint256 _troveId) {
        ITroveManager _tm = ITroveManager(address(LENDER.TROVE_MANAGER()));
        IPriceOracle _oracle = IPriceOracle(_tm.price_oracle());
        ERC20 _collateralToken = ERC20(_tm.collateral_token());

        // Aim for a 10% buffer above MCR
        uint256 _targetCR = _tm.minimum_collateral_ratio() * 110 / 100;
        uint256 _collateralNeeded = (_borrowAmount * _targetCR / ASSET_PRECISION) * 1e36 / _oracle.get_price();

        // Modest interest rate above min
        uint256 _rate = _tm.min_annual_interest_rate() * 20;

        airdrop(_collateralToken, _borrower, _collateralNeeded);

        vm.startPrank(_borrower);
        _collateralToken.approve(address(_tm), _collateralNeeded);
        _troveId = _tm.open_trove(
            block.timestamp, // owner_index
            _collateralNeeded,
            _borrowAmount,
            0, // upper_hint
            0, // lower_hint
            _rate,
            type(uint256).max, // max_upfront_fee
            0, // min_borrow_out
            0 // min_collateral_out
        );
        vm.stopPrank();
    }

    function openAndCloseTrove(
        uint256 _borrowAmount,
        uint256 _holdDuration
    ) public {
        address _borrower = address(77);

        // Open the trove (interest starts accruing on the borrowed amount)
        uint256 _troveId = openTrove(_borrower, _borrowAmount);

        // Hold the trove open so interest accrues
        skip(_holdDuration);

        // Cover any accrued interest before repaying
        ITroveManager _tm = ITroveManager(address(LENDER.TROVE_MANAGER()));
        uint256 _debt = _tm.get_trove_debt_after_interest(_troveId);
        uint256 _balance = asset.balanceOf(_borrower);
        if (_debt > _balance) airdrop(asset, _borrower, _debt - _balance);

        // Repay the trove and return the collateral; the upfront fee plus accrued interest stay with the Lender
        vm.startPrank(_borrower);
        asset.approve(address(_tm), _debt);
        _tm.close_trove(_troveId);
        vm.stopPrank();

        // Report the Lender
        vm.prank(LENDER.keeper());
        LENDER.report();

        // Skip profit unlock time
        skip(LENDER.profitMaxUnlockTime());
    }

    function takeAuction(
        uint256 _auctionId,
        IAuction _auction
    ) public {
        address _liquidator = address(88);

        // Skip time until the auction price reaches the oracle price
        uint256 _stepDuration = _auction.step_duration();
        IPriceOracle _oracle = IPriceOracle(ITroveManager(address(LENDER.TROVE_MANAGER())).price_oracle());
        uint256 _targetPrice = _oracle.get_price(false);
        uint256 _currentPrice = _auction.get_price(_auctionId, block.timestamp);
        uint256 _steps = 0;

        while (_currentPrice > _targetPrice && _steps < 1440) {
            _steps++;
            _currentPrice = _auction.get_price(_auctionId, block.timestamp + _steps * _stepDuration);
        }

        if (_steps > 0) skip(_steps * _stepDuration);

        uint256 _amountNeeded = _auction.get_needed_amount(_auctionId, type(uint256).max, block.timestamp);
        airdrop(asset, _liquidator, _amountNeeded);

        vm.startPrank(_liquidator);
        asset.approve(address(_auction), _amountNeeded);
        _auction.take(_auctionId, type(uint256).max, _liquidator, "");
        vm.stopPrank();
    }

    function checkStrategyTotals(
        IStrategy _strategy,
        uint256 _totalAssets,
        uint256 _totalDebt,
        uint256 _totalIdle
    ) public {
        uint256 _assets = _strategy.totalAssets();
        uint256 _balance = ERC20(_strategy.asset()).balanceOf(address(_strategy));
        uint256 _idle = _balance > _assets ? _assets : _balance;
        uint256 _debt = _assets - _idle;
        assertEq(_assets, _totalAssets, "!totalAssets");
        assertEq(_debt, _totalDebt, "!totalDebt");
        assertEq(_idle, _totalIdle, "!totalIdle");
        assertEq(_totalAssets, _totalDebt + _totalIdle, "!Added");
    }

}
