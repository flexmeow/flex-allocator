// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.30;

import {IBaseHealthCheck} from "@periphery/Bases/HealthCheck/IBaseHealthCheck.sol";

import {ILender} from "../interfaces/ILender.sol";

interface IStrategy is IBaseHealthCheck {

    // ============================================================================================
    // Constants
    // ============================================================================================

    function LENDER() external view returns (ILender);

    function EXIT_ROUTER() external view returns (address);

    // ============================================================================================
    // Storage
    // ============================================================================================

    function pendingAuctionId() external view returns (uint256);

    // ============================================================================================
    // Management functions
    // ============================================================================================

    function setKeeper(
        address _keeper
    ) external;

    function setPendingManagement(
        address _management
    ) external;

    function setPerformanceFeeRecipient(
        address _performanceFeeRecipient
    ) external;

    function forceFreeFunds(
        uint256 _amount,
        uint256 _minOut
    ) external returns (uint256);

    function deployIdleFunds(
        uint256 _amount
    ) external returns (uint256);

    // ============================================================================================
    // Proceeds receiver
    // ============================================================================================

    function setProceedsReceiver(
        address _receiver,
        address _vault
    ) external;

}
