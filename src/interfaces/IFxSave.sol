// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.30;

interface IFxSave {

    function requestRedeem(
        uint256 _shares
    ) external returns (uint256);

    function claim(
        address _receiver
    ) external;

}
