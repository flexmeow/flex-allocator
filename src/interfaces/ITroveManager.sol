// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.30;

interface ITroveManager {

    function total_weighted_debt() external view returns (uint256);
    function unclaimed_protocol_fees() external view returns (uint256);
    function dutch_desk() external view returns (address);
    function collateral_token() external view returns (address);
    function sync_total_debt() external returns (uint256);
    function redeem(
        uint256 debt_amount,
        address receiver
    ) external;

}
