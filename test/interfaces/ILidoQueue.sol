// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface ILidoQueue {

    function finalize(
        uint256 _lastRequestIdToBeFinalized,
        uint256 _maxShareRate
    ) external payable;

    function prefinalize(
        uint256[] calldata _batches,
        uint256 _maxShareRate
    ) external view returns (uint256 ethToLock, uint256 sharesToBurn);

}
