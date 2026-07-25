// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IStETH {

    function getPooledEthByShares(
        uint256 _sharesAmount
    ) external view returns (uint256);

}
