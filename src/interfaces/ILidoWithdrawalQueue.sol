// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.30;

interface ILidoWithdrawalQueue {

    function requestWithdrawals(
        uint256[] calldata _amounts,
        address _owner
    ) external returns (uint256[] memory requestIds);

    function claimWithdrawal(
        uint256 _requestId
    ) external;

}
