// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.30;

import {ILockedVault} from "../interfaces/ILockedVault.sol";

import {CooldownFlexLenderStrategy, IERC4626} from "./CooldownStrategy.sol";

/// @title Locked yvUSD Flex Lender Strategy
/// @author Flex
/// @notice Flex Lender Strategy for Locked yvUSD collateral markets. Collateral taken in kind from
///         redemption auctions is unwound back to the asset through Locked yvUSD's cooldown
contract LockedYvusdFlexLenderStrategy is CooldownFlexLenderStrategy {

    // ============================================================================================
    // Constants
    // ============================================================================================

    /// @notice USDC token
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /// @notice yvUSD vault, the collateral's asset
    IERC4626 public constant YVUSD = IERC4626(0x696d02Db93291651ED510704c9b286841d506987);

    // ============================================================================================
    // Constructor
    // ============================================================================================

    /// @notice Constructor
    /// @param _lender The address of the Lender contract
    /// @param _exitRouter The address of the exit router
    /// @param _name The name of the strategy
    constructor(
        address _lender,
        address _exitRouter,
        string memory _name
    ) CooldownFlexLenderStrategy(USDC, _lender, _exitRouter, _name) {
        // Make sure the collateral (Locked yvUSD) unwraps to yvUSD
        require(COLLATERAL.asset() == address(YVUSD), "!yvusd");
    }

    // ============================================================================================
    // Cooldown
    // ============================================================================================

    /// @notice Start the cooldown on loose Locked yvUSD, replacing any cooldown in progress
    /// @dev Only callable by management
    /// @dev The withdrawal window opens after `cooldownDuration` and lasts `withdrawalWindow`,
    ///      missing it means starting over
    /// @dev Calling while `pendingRedemptions > 0` restarts everything, the cooldown timer and
    ///      the pending accounting, so an in-progress cooldown is lost
    /// @param _shares The amount of Locked yvUSD to unwind, capped by the loose balance
    /// @return _pendingAssets The amount of asset the cooled shares are worth
    function initiateCooldown(
        uint256 _shares
    ) external onlyManagement returns (uint256 _pendingAssets) {
        // Cap the shares by the loose collateral balance
        _shares = _capToBalance(COLLATERAL, _shares);

        // Start the cooldown, replacing any in progress
        ILockedVault(address(COLLATERAL)).startCooldown(_shares);

        // Record the cooled amount. Locked yvUSD --> yvUSD --> asset
        _pendingAssets = YVUSD.convertToAssets(COLLATERAL.convertToAssets(_shares));
        pendingRedemptions = _pendingAssets;
    }

    /// @notice Redeem the cooled Locked yvUSD for the asset, within the withdrawal window
    /// @dev Only callable by management
    /// @param _minOut Minimum amount of asset to receive
    /// @return _assets The amount of asset received
    function claimCooldown(
        uint256 _minOut
    ) external onlyManagement returns (uint256 _assets) {
        // Only the cooled shares are redeemable, and only within the window
        uint256 _shares = COLLATERAL.maxRedeem(address(this));
        require(_shares > 0, "!claim");

        // Locked yvUSD --> yvUSD --> asset
        uint256 _yvusdAmount = COLLATERAL.redeem(_shares, address(this), address(this));
        _assets = YVUSD.redeem(_yvusdAmount, address(this), address(this));
        require(_assets >= _minOut, "shrekt");

        // Clear the claimed amount
        pendingRedemptions = _assets >= pendingRedemptions ? 0 : pendingRedemptions - _assets;
    }

}
