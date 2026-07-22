// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {StrategyAprOracle} from "../src/periphery/StrategyAprOracle.sol";

import "./Base.sol";

contract StrategyAprOracleTests is Base {

    StrategyAprOracle public aprOracle;

    function setUp() public override {
        Base.setUp();
        aprOracle = new StrategyAprOracle();
    }

    function test_setup() public {
        assertEq(aprOracle.name(), "Flex Lender Strategy APR Oracle", "E0");
        assertEq(address(strategy.LENDER()), address(LENDER), "E1");
    }

    // The strategy supplies the Lender, so the oracle must return the Lender's APR:
    // total_weighted_debt * WAD / ((totalAssets + delta) * assetPrecision)
    function test_aprAfterDebtChange_matchesFormula(
        uint256 _amount,
        uint256 _delta
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        // Lend through the strategy and borrow half so there's a non-trivial APR
        mintAndDepositIntoStrategy(strategy, user, _amount);
        openTrove(address(77), _amount / 2);

        uint256 _totalAssets = LENDER.totalAssets();
        _delta = bound(_delta, 0, _totalAssets * 10);

        uint256 _totalWeightedDebt = LENDER.TROVE_MANAGER().total_weighted_debt();
        uint256 _expected = _totalWeightedDebt * WAD / ((_totalAssets + _delta) * ASSET_PRECISION);

        assertGt(_expected, 0, "E0");
        assertEq(aprOracle.aprAfterDebtChange(address(strategy), int256(_delta)), _expected, "E1");
    }

    function test_aprAfterDebtChange_deltaMovesApr(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        // Lend through the strategy and borrow half so there's a non-trivial APR
        mintAndDepositIntoStrategy(strategy, user, _amount);
        openTrove(address(77), _amount / 2);

        uint256 _totalAssets = LENDER.totalAssets();
        uint256 _apr = aprOracle.aprAfterDebtChange(address(strategy), 0);
        assertGt(_apr, 0, "E0");

        // Double the deposit --> APR should be cut in half
        assertApproxEqRel(aprOracle.aprAfterDebtChange(address(strategy), int256(_totalAssets)), _apr / 2, 1e12, "E1"); // 0.0001%

        // Halve the deposit --> APR should double
        assertApproxEqRel(aprOracle.aprAfterDebtChange(address(strategy), -int256(_totalAssets / 2)), _apr * 2, 1e12, "E2"); // 0.0001%
    }

    function test_aprAfterDebtChange_revertsOnExcessiveNegativeDelta(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        // Lend through the strategy and borrow half so the oracle doesn't short-circuit on zero debt
        mintAndDepositIntoStrategy(strategy, user, _amount);
        openTrove(address(77), _amount / 2);

        uint256 _totalAssets = LENDER.totalAssets();

        // Delta exceeds totalAssets -- should revert
        vm.expectRevert();
        aprOracle.aprAfterDebtChange(address(strategy), -int256(_totalAssets + 1));
    }

}
