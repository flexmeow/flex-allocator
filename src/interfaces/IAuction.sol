// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.30;

interface IAuction {

    struct AuctionInfo {
        uint256 kick_timestamp;
        uint256 initial_amount;
        uint256 current_amount;
        uint256 maximum_amount;
        uint256 amount_received;
        uint256 starting_price;
        uint256 minimum_price;
        address receiver;
        address surplus_receiver;
    }

    function auctions(
        uint256 auction_id
    ) external view returns (AuctionInfo memory);

    function is_active(
        uint256 auction_id
    ) external view returns (bool);

    function take(
        uint256 auction_id
    ) external returns (uint256);

}
