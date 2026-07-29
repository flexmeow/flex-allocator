// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.30;

interface IAllocatorVault {

    function redeem(
        uint256 shares,
        address receiver,
        address owner,
        uint256 max_loss
    ) external returns (uint256);

}
