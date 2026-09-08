// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IInfiniFiGatewayV1} from "../interfaces/IInfiniFiGatewayV1.sol";
import {IRedeemController} from "../interfaces/IRedeemController.sol";

import {CooldownFlexLenderStrategy, ERC20, IERC4626} from "./CooldownStrategy.sol";

/// @title Infinifi Flex Lender Strategy
/// @author Flex
/// @notice Flex Lender Strategy for siUSD collateral markets. Collateral taken in kind from redemption
///         auctions is unwound back to the asset through InfiniFi's redemption queue
contract InfinifiFlexLenderStrategy is CooldownFlexLenderStrategy {

    using SafeERC20 for ERC20;
    using SafeERC20 for IERC4626;

    // ============================================================================================
    // Constants
    // ============================================================================================

    /// @notice USDC token
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /// @notice iUSD receipt token
    ERC20 public immutable IUSD;

    /// @notice InfiniFi Gateway
    IInfiniFiGatewayV1 public constant GATEWAY = IInfiniFiGatewayV1(0x3f04b65Ddbd87f9CE0A2e7Eb24d80e7fb87625b5);

    // ============================================================================================
    // Storage
    // ============================================================================================

    /// @notice iUSD queued in InfiniFi's redemption controller, which has no per user view for it
    uint256 public queuedReceipts;

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
        // Set the receipt token (iUSD) and make sure the collateral (siUSD) unwraps to it
        IUSD = ERC20(COLLATERAL.asset());
        require(address(IUSD) == 0x48f9e38f3070AD8945DFEae3FA70987722E3D89c, "!iusd");

        // Max approve the Gateway to pull the tokens being unwound
        COLLATERAL.forceApprove(address(GATEWAY), type(uint256).max);
        IUSD.forceApprove(address(GATEWAY), type(uint256).max);
    }

    // ============================================================================================
    // Public view functions
    // ============================================================================================

    /// @inheritdoc CooldownFlexLenderStrategy
    function pendingRedemptions() public view override returns (uint256) {
        // Loose siUSD plus the queued iUSD, valued as asset
        uint256 _receipts = COLLATERAL.convertToAssets(COLLATERAL.balanceOf(address(this))) + queuedReceipts;
        return _redeemController().receiptToAsset(_receipts);
    }

    // ============================================================================================
    // Cooldown
    // ============================================================================================

    /// @notice Unstake loose siUSD and redeem it for the asset, queueing whatever cannot be redeemed instantly
    /// @dev Only callable by management
    /// @param _shares The amount of siUSD to unwind, capped by the loose balance
    /// @param _minAssetsOut The minimum amount of asset redeemed instantly, for when the redemption
    ///        is expected to skip the queue
    /// @return _assetsOut The amount of asset received instantly
    /// @return _pendingAssets The amount of asset queued in InfiniFi's redemption controller
    function initiateCooldown(
        uint256 _shares,
        uint256 _minAssetsOut
    ) external onlyManagement returns (uint256 _assetsOut, uint256 _pendingAssets) {
        // Cap the shares by the loose collateral balance
        _shares = _capToBalance(COLLATERAL, _shares);

        // siUSD --> iUSD
        uint256 _iusdAmount = GATEWAY.unstake(address(this), _shares);

        // iUSD --> asset. Anything not redeemed instantly is queued in the redemption controller
        IRedeemController _redeemController_ = _redeemController();
        uint256 _preBalance = asset.balanceOf(address(this));
        uint256 _preQueued = _redeemController_.totalEnqueuedRedemptions();
        GATEWAY.redeem(address(this), _iusdAmount, 0);
        _assetsOut = asset.balanceOf(address(this)) - _preBalance;

        // Make sure we got at least the minimum instant amount requested
        require(_assetsOut >= _minAssetsOut, "shrekt");

        // Record the queued iUSD, the queue only grows within our redemption
        uint256 _queued = _redeemController_.totalEnqueuedRedemptions() - _preQueued;
        queuedReceipts += _queued;
        _pendingAssets = _redeemController_.receiptToAsset(_queued);
    }

    /// @notice Claim queued redemptions from InfiniFi
    /// @dev Only callable by management
    /// @return _assets The amount of asset claimed
    function claimCooldown() external onlyManagement returns (uint256 _assets) {
        IRedeemController _redeemController_ = _redeemController();
        require(_redeemController_.userPendingClaims(address(this)) > 0, "!claim");

        uint256 _preBalance = asset.balanceOf(address(this));
        GATEWAY.claimRedemption();
        _assets = asset.balanceOf(address(this)) - _preBalance;
        require(_assets > 0, "!assets");

        // Settle the claimed iUSD, converted back at the controller's rate
        uint256 _receipts = _assets * _WAD / _redeemController_.receiptToAsset(_WAD);
        queuedReceipts = _receipts >= queuedReceipts ? 0 : queuedReceipts - _receipts;
    }

    // ============================================================================================
    // Internal view functions
    // ============================================================================================

    function _redeemController() internal view returns (IRedeemController) {
        return IRedeemController(GATEWAY.getAddress("redeemController"));
    }

}
