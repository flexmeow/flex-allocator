// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "./Base.sol";

/// @dev A redemption walks at most 1,000 Troves and auctions only what it freed, while the Lender still burns
///      every share it was asked to redeem. The minimum collateral out catches the shortfall
contract PartialRedemptionTests is Base {

    // Tokens
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    // wstETH/WETH Morpho oracle
    address public constant MORPHO_ORACLE = 0xbD60A6770b27E084E8617335ddE769241B0e71D8;

    // Troves a redemption walks at most
    uint256 public constant MAX_REDEMPTIONS = 1_000;

    // Twice what the walked Troves owe
    uint256 public constant AMOUNT = 200 ether;

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

    function test_forceFreeFunds_partialRedemption() public {
        mintAndDepositIntoStrategy(strategy, user, AMOUNT);
        _stuffTroves();

        IDutchDesk _dutchDesk = IDutchDesk(ITroveManager(address(LENDER.TROVE_MANAGER())).dutch_desk());
        IAuction _auction = IAuction(_dutchDesk.auction());
        uint256 _auctionId = _dutchDesk.nonce();
        uint256 _minCollateralOut = _collateralFor(AMOUNT) * 99 / 100;

        // The walk stops after 1,000 Troves, so the redemption auctions about half of what we free
        vm.prank(management);
        vm.expectRevert("!collateral");
        strategy.forceFreeFunds(AMOUNT, 0, _minCollateralOut);

        // Without the minimum, every Lender share is burned but the auction only owes about half of them
        vm.prank(management);
        strategy.forceFreeFunds(AMOUNT, 0, 0);

        assertEq(LENDER.balanceOf(address(strategy)), 0, "E0");
        assertApproxEqRel(_auction.auctions(_auctionId).maximum_amount, AMOUNT / 2, 1e16, "E1"); // 1%
    }

    // ============================================================================================
    // Helpers
    // ============================================================================================

    /// @dev Open 1,000 minimum debt Troves at the minimum rate, then borrow the rest of the Lender's idle above it
    function _stuffTroves() internal {
        ITroveManager _tm = ITroveManager(address(LENDER.TROVE_MANAGER()));
        ERC20 _collateralToken = ERC20(_tm.collateral_token());
        uint256 _minDebt = _tm.min_debt();
        uint256 _collateral = _collateralFor(_minDebt) * 2; // 200% CR

        address _attacker = address(0xA11CE);
        airdrop(_collateralToken, _attacker, _collateral * MAX_REDEMPTIONS);

        vm.startPrank(_attacker);
        _collateralToken.approve(address(_tm), type(uint256).max);
        uint256 _troveId;
        for (uint256 i; i < MAX_REDEMPTIONS; ++i) {
            // Append at the tail of the sorted list, where the walk starts
            _troveId = _tm.open_trove(i, _collateral, _minDebt, _troveId, 0, _tm.min_annual_interest_rate(), type(uint256).max, 0, 0);
        }
        vm.stopPrank();

        openTrove(address(77), asset.balanceOf(address(LENDER)));
    }

    /// @dev Collateral worth `_amount` at the oracle price
    function _collateralFor(
        uint256 _amount
    ) internal view returns (uint256) {
        return _amount * 1e36 / IPriceOracle(ITroveManager(address(LENDER.TROVE_MANAGER())).price_oracle()).get_price();
    }

}
