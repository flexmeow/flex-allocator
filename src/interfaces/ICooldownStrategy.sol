// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.30;

import {IStrategy} from "./IStrategy.sol";

interface ICooldownStrategy is IStrategy {

    // ============================================================================================
    // Storage
    // ============================================================================================

    function COLLATERAL() external view returns (address);

    function PENDING_DUST() external view returns (uint256);

    function pendingRedemptions() external view returns (uint256);

    function ignorePending() external view returns (bool);

    // ============================================================================================
    // Management functions
    // ============================================================================================

    function setIgnorePending(
        bool _ignorePending
    ) external;

    // ============================================================================================
    // Cooldown
    // ============================================================================================

    function forceFreeFundsInKind(
        uint256 _amount,
        uint256 _minOut
    ) external returns (uint256);

}
