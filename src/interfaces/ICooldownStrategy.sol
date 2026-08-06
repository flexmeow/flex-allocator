// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.30;

import {IStrategy} from "./IStrategy.sol";

interface ICooldownStrategy is IStrategy {

    // ============================================================================================
    // Storage
    // ============================================================================================

    function COLLATERAL() external view returns (address);

    function pendingRedemptions() external view returns (uint256);

    // ============================================================================================
    // Cooldown
    // ============================================================================================

    function forceFreeFundsInKind(
        uint256 _amount,
        uint256 _minOut
    ) external returns (uint256);

    function zeroPendingRedemptions() external;

}
