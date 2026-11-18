// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "./Base.sol";

/// @dev With an 18 decimals collateral and a 6 decimals asset, a small enough auction remainder costs nothing,
///      so it can never be taken and the auction never settles. That must not block the strategy
contract DustAuctionTests is Base {

    // Tokens
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    // wstETH/USDC Morpho oracle
    address public constant MORPHO_ORACLE = 0x48F7E36EB6B826B2dF4B2E630B62Cd25e89E40e2;

    // Amount deposited and force freed
    uint256 public constant AMOUNT = 100_000e6;

    // ============================================================================================
    // Deployment hooks
    // ============================================================================================

    /// @dev Deploy a local v2 wstETH/USDC market
    function _deployLender() internal override returns (address) {
        address _priceOracle = deployCode("lib/flex-contracts/out/morpho_oracle.vy/morpho_oracle.json", abi.encode(MORPHO_ORACLE, USDC, WSTETH));
        return deployFlexMarket(USDC, WSTETH, _priceOracle, 500e6); // 500 USDC minimum debt
    }

    // ============================================================================================
    // Tests
    // ============================================================================================

    function test_forceFreeFunds_dustRemainder() public {
        mintAndDepositIntoStrategy(strategy, user, AMOUNT);

        // Drain the Lender's idle so the force free kicks an auction
        openTrove(address(77), AMOUNT);

        IDutchDesk _dutchDesk = IDutchDesk(ITroveManager(address(LENDER.TROVE_MANAGER())).dutch_desk());
        IAuction _auction = IAuction(_dutchDesk.auction());
        uint256 _auctionId = _dutchDesk.nonce();

        vm.prank(management);
        strategy.forceFreeFunds(AMOUNT, 0, 0);

        // A taker buys everything but 1 wei of collateral
        address _taker = address(88);
        uint256 _takeAmount = _auction.auctions(_auctionId).current_amount - 1;
        uint256 _neededAmount = _auction.get_needed_amount(_auctionId, _takeAmount, block.timestamp);
        airdrop(asset, _taker, _neededAmount);
        vm.startPrank(_taker);
        asset.approve(address(_auction), _neededAmount);
        _auction.take(_auctionId, _takeAmount, _taker, "");

        // The remainder costs nothing, so it can never be taken and the auction never settles
        assertEq(_auction.get_needed_amount(_auctionId, type(uint256).max, block.timestamp), 0, "E0");
        vm.expectRevert("!needed_amount");
        _auction.take(_auctionId, type(uint256).max, _taker, "");
        vm.stopPrank();
        assertGt(_auction.auctions(_auctionId).kick_timestamp, 0, "E1");

        // Reporting and freeing more funds still work. Allow for the rounding on the take
        vm.prank(management);
        strategy.setLossLimitRatio(1);
        vm.prank(keeper);
        strategy.report();
        vm.prank(management);
        strategy.forceFreeFunds(AMOUNT, 0, 0);

        // Same after the auction expires and is re-kicked, the remainder still costs nothing
        skip(_auction.auction_length() + 1);
        _dutchDesk.re_kick(_auctionId);
        assertEq(_auction.get_needed_amount(_auctionId, type(uint256).max, block.timestamp), 0, "E2");
        vm.prank(keeper);
        strategy.report();
        vm.prank(management);
        strategy.forceFreeFunds(AMOUNT, 0, 0);
    }

}
