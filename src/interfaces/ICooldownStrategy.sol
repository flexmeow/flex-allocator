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

    function initiateCooldown(
        uint256 _shares
    ) external;

    function zeroPendingRedemptions() external;

}
