// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IInfiniFiGateway {

    function mint(
        address _to,
        uint256 _amount
    ) external returns (uint256);

}
