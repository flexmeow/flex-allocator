// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.30;

import {IAllocatorVault} from "../interfaces/IAllocatorVault.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";

/// @title Flex Exit Router
/// @author Flex
/// @notice Entry point for exits that need a collateral redemption
contract FlexExitRouter {

    // ============================================================================================
    // Redeem
    // ============================================================================================

    /// @notice Redeem allocator vault shares, routing the strategies' withdrawals to the receiver
    /// @dev The owner must first approve this router for `_shares` of `_vault`
    /// @param _vault The allocator vault to redeem from
    /// @param _shares The amount of vault shares to burn
    /// @param _receiver The address to receive the withdrawal and any kicked auction's proceeds
    /// @param _owner The owner of the shares
    /// @param _maxLoss Acceptable loss in basis points
    /// @param _strategies The strategies to set the receiver on
    /// @return _assets The amount of asset delivered by the vault
    function redeem(
        address _vault,
        uint256 _shares,
        address _receiver,
        address _owner,
        uint256 _maxLoss,
        IStrategy[] calldata _strategies
    ) external returns (uint256 _assets) {
        // Set the receiver
        _setProceedsReceiver(_strategies, _receiver);

        // Redeem the shares from the vault
        _assets = IAllocatorVault(_vault).redeem(_shares, _receiver, _owner, _maxLoss);

        // Clear the receiver
        _setProceedsReceiver(_strategies, address(0));
    }

    // ============================================================================================
    // Internal mutative functions
    // ============================================================================================

    /// @dev Set the proceeds receiver on every given strategy
    function _setProceedsReceiver(
        IStrategy[] calldata _strategies,
        address _receiver
    ) internal {
        for (uint256 i; i < _strategies.length; ++i) {
            _strategies[i].setProceedsReceiver(_receiver);
        }
    }

}
