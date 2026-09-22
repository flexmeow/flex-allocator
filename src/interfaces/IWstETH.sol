// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.30;

interface IWstETH {

    function unwrap(
        uint256 _wstETHAmount
    ) external returns (uint256);

    function stETH() external view returns (address);

    function getStETHByWstETH(
        uint256 _wstETHAmount
    ) external view returns (uint256);

}
