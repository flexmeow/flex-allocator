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
    /// @dev The caller must first approve this router for `_shares` of `_vault`
    /// @param _vault The allocator vault to redeem from
    /// @param _shares The amount of vault shares to burn
    /// @param _receiver The address to receive the withdrawal and any kicked auction's proceeds
    /// @param _maxLoss Acceptable loss in basis points
    /// @param _minCollateralOut Minimum amount of collateral auctioned by each strategy's redemption
    /// @param _strategies The strategies to set the receiver on
    /// @return _assets The amount of asset delivered by the vault
    function redeem(
        address _vault,
        uint256 _shares,
        address _receiver,
        uint256 _maxLoss,
        uint256[] calldata _minCollateralOut,
        IStrategy[] calldata _strategies
    ) external returns (uint256 _assets) {
        // Cache the next auction ids, in case the redemption kicks any
        uint256[] memory _nextAuctionIds = _getNextAuctionIds(_strategies);

        // Set the receiver. The strategies reject a vault they are not allowed to be held by
        _setProceedsReceiver(_strategies, _receiver, _vault);

        // Redeem the shares from the vault
        _assets = IAllocatorVault(_vault).redeem(_shares, _receiver, msg.sender, _maxLoss);

        // Clear the receiver
        _setProceedsReceiver(_strategies, address(0), _vault);

        // Make sure each redemption auctioned at least the minimum collateral requested
        _checkMinCollateralOut(_strategies, _nextAuctionIds, _minCollateralOut);
    }

    // ============================================================================================
    // Internal view functions
    // ============================================================================================

    /// @dev Get the next auction id of every given strategy
    function _getNextAuctionIds(
        IStrategy[] calldata _strategies
    ) internal view returns (uint256[] memory _nextAuctionIds) {
        _nextAuctionIds = new uint256[](_strategies.length);
        for (uint256 i; i < _strategies.length; ++i) {
            _nextAuctionIds[i] = _strategies[i].DUTCH_DESK().nonce();
        }
    }

    /// @dev Check every given strategy's kicked auction, if any, against its minimum collateral
    function _checkMinCollateralOut(
        IStrategy[] calldata _strategies,
        uint256[] memory _nextAuctionIds,
        uint256[] calldata _minCollateralOut
    ) internal view {
        for (uint256 i; i < _strategies.length; ++i) {
            require(
                _strategies[i].DUTCH_DESK().nonce() == _nextAuctionIds[i]
                    || _strategies[i].AUCTION().auctions(_nextAuctionIds[i]).initial_amount >= _minCollateralOut[i],
                "!collateral"
            );
        }
    }

    // ============================================================================================
    // Internal mutative functions
    // ============================================================================================

    /// @dev Set the proceeds receiver on every given strategy
    function _setProceedsReceiver(
        IStrategy[] calldata _strategies,
        address _receiver,
        address _vault
    ) internal {
        for (uint256 i; i < _strategies.length; ++i) {
            _strategies[i].setProceedsReceiver(_receiver, _vault);
        }
    }

}
