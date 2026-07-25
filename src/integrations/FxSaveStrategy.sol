// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICurveStableSwap} from "../interfaces/ICurveStableSwap.sol";
import {IFxSave} from "../interfaces/IFxSave.sol";
import {IFxUSDBasePool} from "../interfaces/IFxUSDBasePool.sol";

import {CooldownFlexLenderStrategy, ERC20} from "./CooldownStrategy.sol";

/// @title fxSAVE Flex Lender Strategy
/// @author Flex
/// @notice Flex Lender Strategy for fxSAVE collateral markets. Collateral taken in kind from redemption
///         auctions is unwound through f(x)'s base pool redemption queue, which pays out a mix of
///         USDC and fxUSD. The fxUSD leg is swapped back to the asset through Curve
contract FxSaveFlexLenderStrategy is CooldownFlexLenderStrategy {

    using SafeERC20 for ERC20;

    // ============================================================================================
    // Constants
    // ============================================================================================

    /// @notice Coin indices in the Curve pool
    int128 internal constant _USDC_INDEX = 0;
    int128 internal constant _FXUSD_INDEX = 1;

    /// @notice Scales an 18-decimals fxBASE amount valued by the 18-decimals nav to 6-decimals asset terms
    uint256 internal constant _NAV_TO_ASSET_SCALE = 1e30;

    /// @notice USDC token
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /// @notice fxUSD token
    ERC20 public constant FXUSD = ERC20(0x085780639CC2cACd35E474e71f4d000e2405d8f6);

    /// @notice fxBASE pool, the underlying of fxSAVE
    IFxUSDBasePool public constant FXBASE = IFxUSDBasePool(0x65C9A641afCEB9C0E6034e558A319488FA0FA3be);

    /// @notice Curve USDC/fxUSD pool
    ICurveStableSwap public constant CURVE_POOL = ICurveStableSwap(0x5018BE882DccE5E3F2f3B0913AE2096B9b3fB61f);

    // ============================================================================================
    // Constructor
    // ============================================================================================

    /// @notice Constructor
    /// @param _lender The address of the Lender contract
    /// @param _name The name of the strategy
    constructor(
        address _lender,
        string memory _name
    ) CooldownFlexLenderStrategy(USDC, _lender, _name) {
        // Make sure the collateral (fxSAVE) unwraps to fxBASE
        require(COLLATERAL.asset() == address(FXBASE), "!fxbase");

        // Max approve the Curve pool to pull the fxUSD being swapped
        FXUSD.forceApprove(address(CURVE_POOL), type(uint256).max);
    }

    // ============================================================================================
    // Cooldown
    // ============================================================================================

    /// @notice Queue loose fxSAVE for redemption through fxBASE's redemption queue
    /// @dev Only callable by management
    /// @dev Requests accumulate, but every request resets the unlock clock for the whole queued amount
    /// @param _shares The amount of fxSAVE to unwind, capped by the loose balance
    /// @return _pendingAssets The amount of asset queued in fxBASE's redemption queue
    function initiateCooldown(
        uint256 _shares
    ) external onlyManagement returns (uint256 _pendingAssets) {
        // Cap the shares by the loose collateral balance
        _shares = _capToBalance(COLLATERAL, _shares);

        // fxSAVE --> fxBASE, queued for redemption
        uint256 _baseAssets = IFxSave(address(COLLATERAL)).requestRedeem(_shares);

        // Record the queued amount, valued in asset terms via fxBASE's nav
        _pendingAssets = _baseAssets * FXBASE.nav() / _NAV_TO_ASSET_SCALE;
        pendingRedemptions += _pendingAssets;
    }

    /// @notice Claim the queued redemption from fxBASE once the cooldown passed
    /// @dev Only callable by keepers
    /// @dev Pays out the whole queued amount as a mix of USDC and fxUSD
    /// @return _assetsOut The amount of asset received
    /// @return _fxusdOut The amount of fxUSD received
    function claimCooldown() external onlyKeepers returns (uint256 _assetsOut, uint256 _fxusdOut) {
        require(pendingRedemptions > 0, "!pending");

        // The claim always empties the queue
        pendingRedemptions = 0;

        // Claim the whole queued amount
        uint256 _preAssetBalance = asset.balanceOf(address(this));
        uint256 _preFxusdBalance = FXUSD.balanceOf(address(this));
        IFxSave(address(COLLATERAL)).claim(address(this));
        _assetsOut = asset.balanceOf(address(this)) - _preAssetBalance;
        _fxusdOut = FXUSD.balanceOf(address(this)) - _preFxusdBalance;
        require(_assetsOut + _fxusdOut > 0, "!assets");
    }

    /// @notice Swap loose fxUSD to the asset through Curve
    /// @dev Only callable by management
    /// @param _amount The amount of fxUSD to swap, capped by the loose balance
    /// @param _minOut Minimum amount of asset to receive
    /// @return The amount of asset received
    function swapFxUsd(
        uint256 _amount,
        uint256 _minOut
    ) external onlyManagement returns (uint256) {
        // Cap the amount by the loose fxUSD balance
        _amount = _capToBalance(FXUSD, _amount);

        // fxUSD --> asset
        return CURVE_POOL.exchange(_FXUSD_INDEX, _USDC_INDEX, _amount, _minOut);
    }

}
