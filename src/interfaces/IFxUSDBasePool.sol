// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.30;

interface IFxUSDBasePool {

    function nav() external view returns (uint256);

    function redeemCoolDownPeriod() external view returns (uint256);

}
