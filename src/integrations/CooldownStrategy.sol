// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.30;

import {IERC20, IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {BaseStrategy, ERC20, FlexLenderStrategy} from "../Strategy.sol";

/// @title Cooldown Flex Lender Strategy
/// @author Flex
/// @notice Base for strategies whose collateral is unwound back to the asset through a
///         protocol-specific redemption cooldown
abstract contract CooldownFlexLenderStrategy is FlexLenderStrategy {

    // ============================================================================================
    // Constants
    // ============================================================================================

    /// @notice Collateral token
    IERC4626 public immutable COLLATERAL;

    // ============================================================================================
    // Storage
    // ============================================================================================

    /// @notice Asset amount queued for redemption in the collateral's protocol
    uint256 public pendingRedemptions;

    // ============================================================================================
    // Constructor
    // ============================================================================================

    /// @notice Constructor
    /// @param _asset The address of the borrow token
    /// @param _lender The address of the Lender contract
    /// @param _exitRouter The address of the exit router
    /// @param _name The name of the strategy
    constructor(
        address _asset,
        address _lender,
        address _exitRouter,
        string memory _name
    ) FlexLenderStrategy(_asset, _lender, _exitRouter, _name) {
        // Set the collateral token
        COLLATERAL = IERC4626(LENDER.TROVE_MANAGER().collateral_token());
    }

    // ============================================================================================
    // Cooldown
    // ============================================================================================

    /// @notice Zero out the pending redemptions accounting
    /// @dev Only callable by management
    function zeroPendingRedemptions() external onlyManagement {
        pendingRedemptions = 0;
    }

    // ============================================================================================
    // Internal view functions
    // ============================================================================================

    /// @dev Cap `_amount` by the loose balance of `_token`, reverting on zero
    function _capToBalance(
        IERC20 _token,
        uint256 _amount
    ) internal view returns (uint256) {
        uint256 _balance = _token.balanceOf(address(this));
        if (_amount > _balance) _amount = _balance;
        require(_amount > 0, "!amount");
        return _amount;
    }

    // ============================================================================================
    // Internal mutative functions
    // ============================================================================================

    /// @inheritdoc BaseStrategy
    function _harvestAndReport() internal view override returns (uint256) {
        // Block reports until in-flight cooldowns are claimed
        require(pendingRedemptions == 0, "!cooldown");
        return super._harvestAndReport();
    }

}
