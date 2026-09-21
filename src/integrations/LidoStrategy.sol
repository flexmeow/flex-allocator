// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICurveStableSwap} from "../interfaces/ICurveStableSwap.sol";
import {ILidoWithdrawalQueue} from "../interfaces/ILidoWithdrawalQueue.sol";
import {IWETH} from "../interfaces/IWETH.sol";
import {IWstETH} from "../interfaces/IWstETH.sol";

import {CooldownFlexLenderStrategy, ERC20, Math} from "./CooldownStrategy.sol";

/// @title Lido Flex Lender Strategy
/// @author Flex
/// @notice Flex Lender Strategy for wstETH collateral markets. Collateral taken in kind from redemption
///         auctions is unwound back to the asset 1:1 through Lido's withdrawal queue
contract LidoFlexLenderStrategy is CooldownFlexLenderStrategy {

    using SafeERC20 for ERC20;

    // ============================================================================================
    // Constants
    // ============================================================================================

    /// @notice Coin indices in the Curve pool
    int128 internal constant _ETH_INDEX = 0;
    int128 internal constant _STETH_INDEX = 1;

    /// @notice WETH token
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @notice stETH token
    ERC20 public constant STETH = ERC20(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);

    /// @notice Lido withdrawal queue
    ILidoWithdrawalQueue public constant WITHDRAWAL_QUEUE = ILidoWithdrawalQueue(0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1);

    /// @notice Curve ETH/stETH pool
    ICurveStableSwap public constant CURVE_POOL = ICurveStableSwap(0xDC24316b9AE028F1497c275EB9192a3Ea0f67022);

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
        // Make sure the collateral (wstETH) unwraps to stETH
        require(IWstETH(address(COLLATERAL)).stETH() == address(STETH), "!steth");

        // Max approve the withdrawal queue and the Curve pool to pull the stETH being unwound
        STETH.forceApprove(address(WITHDRAWAL_QUEUE), type(uint256).max);
        STETH.forceApprove(address(CURVE_POOL), type(uint256).max);
    }

    /// @notice Needed to receive ETH from the withdrawal queue
    receive() external payable {}

    // ============================================================================================
    // Public view functions
    // ============================================================================================

    /// @inheritdoc CooldownFlexLenderStrategy
    function pendingRedemptions() public view override returns (uint256 _pending) {
        // wstETH taken in kind, 1:1 with the asset through stETH
        _pending = IWstETH(address(COLLATERAL)).getStETHByWstETH(takenInKind);

        // Unclaimed withdrawal requests
        ILidoWithdrawalQueue.WithdrawalRequestStatus[] memory _statuses =
            WITHDRAWAL_QUEUE.getWithdrawalStatus(WITHDRAWAL_QUEUE.getWithdrawalRequests(address(this)));
        for (uint256 i; i < _statuses.length; ++i) {
            if (!_statuses[i].isClaimed) _pending += _statuses[i].amountOfStETH;
        }
    }

    // ============================================================================================
    // Cooldown
    // ============================================================================================

    /// @notice Unwrap loose wstETH and queue the stETH for a 1:1 withdrawal through Lido
    /// @dev Only callable by management
    /// @dev Lido caps a single request at 1000 stETH, larger unwinds need multiple calls
    /// @param _shares The amount of wstETH to unwind, capped by the loose balance
    /// @return _requestId Lido withdrawal request id, used to claim once finalized
    function initiateCooldown(
        uint256 _shares
    ) external onlyManagement returns (uint256 _requestId) {
        // Cap the shares by the loose collateral balance
        _shares = _capToBalance(COLLATERAL, _shares);

        // Consume the collateral taken in kind variable
        takenInKind -= Math.min(_shares, takenInKind);

        // wstETH --> stETH
        uint256 _pendingAssets = IWstETH(address(COLLATERAL)).unwrap(_shares);

        // Queue the stETH for withdrawal
        uint256[] memory _amounts = new uint256[](1);
        _amounts[0] = _pendingAssets;
        _requestId = WITHDRAWAL_QUEUE.requestWithdrawals(_amounts, address(this))[0];
    }

    /// @notice Claim a finalized withdrawal request from Lido
    /// @dev Only callable by management
    /// @param _requestId The withdrawal request id to claim
    /// @return _assets The amount of asset claimed
    function claimCooldown(
        uint256 _requestId
    ) external onlyManagement returns (uint256 _assets) {
        // Claim the withdrawal and wrap the received ETH
        uint256 _preBalance = asset.balanceOf(address(this));
        WITHDRAWAL_QUEUE.claimWithdrawal(_requestId);
        if (address(this).balance > 0) IWETH(WETH).deposit{value: address(this).balance}();
        _assets = asset.balanceOf(address(this)) - _preBalance;
        require(_assets > 0, "!assets");
    }

    /// @notice Claim finalized withdrawal requests from Lido, with checkpoint hints
    /// @dev Only callable by management
    /// @param _requestIds The withdrawal request ids to claim
    /// @param _hints The checkpoint hints, from the queue's `findCheckpointHints`
    /// @return _assets The amount of asset claimed
    function claimCooldown(
        uint256[] calldata _requestIds,
        uint256[] calldata _hints
    ) external onlyManagement returns (uint256 _assets) {
        // Claim the withdrawals and wrap the received ETH
        uint256 _preBalance = asset.balanceOf(address(this));
        WITHDRAWAL_QUEUE.claimWithdrawals(_requestIds, _hints);
        if (address(this).balance > 0) IWETH(WETH).deposit{value: address(this).balance}();
        _assets = asset.balanceOf(address(this)) - _preBalance;
        require(_assets > 0, "!assets");
    }

    /// @notice Swap loose wstETH to the asset through Curve, skipping the withdrawal queue
    /// @dev Only callable by management
    /// @param _shares The amount of wstETH to swap, capped by the loose balance
    /// @param _minOut Minimum amount of asset to receive
    /// @return _assets The amount of asset received
    function swapWsteth(
        uint256 _shares,
        uint256 _minOut
    ) external onlyManagement returns (uint256 _assets) {
        // Cap the shares by the loose collateral balance
        _shares = _capToBalance(COLLATERAL, _shares);

        // Consume the collateral taken in kind variable
        takenInKind -= Math.min(_shares, takenInKind);

        // wstETH --> stETH
        uint256 _stethAmount = IWstETH(address(COLLATERAL)).unwrap(_shares);

        // stETH --> ETH
        _assets = CURVE_POOL.exchange(_STETH_INDEX, _ETH_INDEX, _stethAmount, _minOut);

        // Wrap the received ETH
        IWETH(WETH).deposit{value: address(this).balance}();
    }

}
