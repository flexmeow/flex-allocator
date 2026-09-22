// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IAvantMinting} from "../interfaces/IAvantMinting.sol";
import {IStakedAvant} from "../interfaces/IStakedAvant.sol";

import {CooldownFlexLenderStrategy, ERC20, Math} from "./CooldownStrategy.sol";

/// @title Avant Flex Lender Strategy
/// @author Flex
/// @notice Flex Lender Strategy for savETH collateral markets. Collateral taken in kind from redemption
///         auctions is unstaked to avETH through savETH's cooldown, then redeemed for the asset by Avant
///         off-chain, against orders signed on this strategy's behalf by a delegated signer
contract AvantFlexLenderStrategy is CooldownFlexLenderStrategy {

    using SafeERC20 for ERC20;

    // ============================================================================================
    // Constants
    // ============================================================================================

    /// @notice WETH token
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @notice avETH token, 1:1 with the asset
    ERC20 public constant AVETH = ERC20(0x9469470C9878bf3d6d0604831d9A3A366156f7EE);

    /// @notice Avant minting contract, redeems avETH for the asset
    IAvantMinting public constant AVANT_MINTING = IAvantMinting(0x09becF6E5e297825D19aA14eD6081A03524532D7);

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
    ) CooldownFlexLenderStrategy(WETH, _lender, _exitRouter, _name) {
        // Make sure the collateral (savETH) unstakes to avETH
        require(COLLATERAL.asset() == address(AVETH), "!aveth");

        // Max approve the minting contract to pull the avETH being redeemed
        AVETH.forceApprove(address(AVANT_MINTING), type(uint256).max);
    }

    // ============================================================================================
    // Public view functions
    // ============================================================================================

    /// @inheritdoc CooldownFlexLenderStrategy
    function pendingRedemptions() public view override returns (uint256 _pending) {
        // savETH taken in kind, and what is cooling in the silo. savETH --> avETH
        (, uint152 _cooling) = IStakedAvant(address(COLLATERAL)).cooldowns(address(this));
        _pending = COLLATERAL.convertToAssets(takenInKind) + _cooling;

        // Loose avETH, waiting to be redeemed
        _pending += AVETH.balanceOf(address(this));
    }

    // ============================================================================================
    // Management functions
    // ============================================================================================

    /// @notice Delegate the signing of Avant redemption orders on this strategy's behalf
    /// @dev Only callable by management
    /// @dev The signer must confirm the delegation on the minting contract. Orders must have this
    ///      strategy as both benefactor and beneficiary
    /// @param _signer The address to delegate to
    function setDelegatedSigner(
        address _signer
    ) external onlyManagement {
        AVANT_MINTING.setDelegatedSigner(_signer);
    }

    // ============================================================================================
    // Cooldown
    // ============================================================================================

    /// @notice Start the cooldown on loose savETH
    /// @dev Only callable by management
    /// @dev Calling while a cooldown is in progress adds to it and restarts its timer
    /// @param _shares The amount of savETH to unwind, capped by the loose balance
    /// @return The amount of avETH cooling
    function initiateCooldown(
        uint256 _shares
    ) external onlyManagement returns (uint256) {
        // Cap the shares by the loose collateral balance
        _shares = _capToBalance(COLLATERAL, _shares);

        // Consume the collateral taken in kind variable
        takenInKind -= Math.min(_shares, takenInKind);

        // savETH --> avETH, into the silo
        return IStakedAvant(address(COLLATERAL)).cooldownShares(_shares);
    }

    /// @notice Unstake the cooled avETH from the silo once the cooldown passed
    /// @dev Only callable by management
    /// @dev The avETH is then redeemed for the asset by Avant, see `setDelegatedSigner`
    /// @return _avethOut The amount of avETH received
    function claimCooldown() external onlyManagement returns (uint256 _avethOut) {
        // Make sure there is something cooled
        IStakedAvant _savETH = IStakedAvant(address(COLLATERAL));
        (uint104 _cooldownEnd, uint152 _cooling) = _savETH.cooldowns(address(this));
        require(_cooling > 0 && block.timestamp >= _cooldownEnd, "!claim");

        // Silo --> avETH
        uint256 _preBalance = AVETH.balanceOf(address(this));
        _savETH.unstake(address(this));
        _avethOut = AVETH.balanceOf(address(this)) - _preBalance;
    }

}
