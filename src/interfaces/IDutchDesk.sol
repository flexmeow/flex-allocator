// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.30;

interface IDutchDesk {

    function auction() external view returns (address);
    function nonce() external view returns (uint256);

}
