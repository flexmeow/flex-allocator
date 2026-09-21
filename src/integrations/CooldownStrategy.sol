// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.30;

import {IERC20, IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BaseStrategy, ERC20, FlexLenderStrategy} from "../Strategy.sol";

/// @title Cooldown Flex Lender Strategy
/// @author Flex
/// @notice Base for strategies whose collateral is unwound back to the asset through a
///         protocol-specific redemption cooldown
abstract contract CooldownFlexLenderStrategy is FlexLenderStrategy {

    // ============================================================================================
    // Constants
    // ============================================================================================

    /// @notice WAD constant
    uint256 internal constant _WAD = 1e18;

    /// @notice Pending amount below which reports are not blocked, for rounding dust the protocol leaves behind
    uint256 public immutable PENDING_DUST;

    /// @notice Collateral token
    IERC4626 public immutable COLLATERAL;

    // ============================================================================================
    // Storage
    // ============================================================================================

    /// @notice Whether reports ignore the pending redemptions, an escape hatch for management
    bool public ignorePending;

    /// @notice Collateral taken in kind and not unwound yet. Storage var and not `balanceOf()` to avoid donations issues
    uint256 public takenInKind;

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

        // Make sure the auction starting price buffer is 0
        require(DUTCH_DESK.starting_price_buffer_percentage() == _WAD, "!buffer");

        // Set the dust to half the asset's decimals, e.g. 0.001 USDC or 1e9 ETH
        PENDING_DUST = 10 ** (asset.decimals() / 2);
    }

    // ============================================================================================
    // Public view functions
    // ============================================================================================

    /// @notice Asset value taken in kind that is not back yet, loose collateral plus whatever is
    ///         queued in the collateral's protocol, read live
    function pendingRedemptions() public view virtual returns (uint256);

    // ============================================================================================
    // Management functions
    // ============================================================================================

    /// @notice Set whether reports ignore the pending redemptions
    /// @dev Only callable by management
    /// @param _ignorePending Whether to ignore the pending redemptions
    function setIgnorePending(
        bool _ignorePending
    ) external onlyManagement {
        ignorePending = _ignorePending;
    }

    // ============================================================================================
    // Cooldown
    // ============================================================================================

    /// @notice Force a withdrawal from the Lender, taking the kicked auction to get the collateral in kind
    /// @dev Only callable by management
    /// @dev The take payment nets out against the proceeds owed to us, so it only succeeds without
    ///      payment when the market has no starting price buffer
    /// @param _amount The amount of asset to free
    /// @param _minOut Minimum amount of asset delivered atomically
    /// @return _freed The actual amount of asset freed
    function forceFreeFundsInKind(
        uint256 _amount,
        uint256 _minOut
    ) external onlyManagement returns (uint256 _freed) {
        // Free the funds, which records the kicked auction if there is one
        _freed = forceFreeFunds(_amount, _minOut);

        // Take the kicked auction, receiving the collateral in kind
        uint256 _auctionId = pendingAuctionId;
        if (AUCTION.is_active(_auctionId)) takenInKind += AUCTION.take(_auctionId);
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
        // Block reports until everything taken in kind is back as asset, unless management says otherwise
        require(ignorePending || pendingRedemptions() <= PENDING_DUST, "!cooldown");
        return super._harvestAndReport();
    }

}
