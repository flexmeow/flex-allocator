// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.30;

interface IAuction {

    function take(
        uint256 auction_id
    ) external returns (uint256);

}
