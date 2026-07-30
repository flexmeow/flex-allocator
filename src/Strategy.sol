// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BaseHealthCheck, ERC20} from "@periphery/Bases/HealthCheck/BaseHealthCheck.sol";
import {BaseStrategy} from "@tokenized-strategy/BaseStrategy.sol";

import {IAuction} from "./interfaces/IAuction.sol";
import {IDutchDesk} from "./interfaces/IDutchDesk.sol";
import {ILender} from "./interfaces/ILender.sol";

/// @title Flex Lender Strategy
/// @author Flex
/// @notice Tokenized Strategy vault that is used by an allocator vault to provide liquidity to a market
contract FlexLenderStrategy is BaseHealthCheck {

    using SafeERC20 for ERC20;

    // ============================================================================================
    // Events
    // ============================================================================================

    /// @notice Emitted when management calls `forceFreeFunds`
    /// @param amount The amount of asset actually freed
    event ForceFreeFunds(uint256 amount);

    /// @notice Emitted when management calls `deployIdleFunds`
    /// @param amount The amount of asset actually deployed
    event DeployIdleFunds(uint256 amount);

    // ============================================================================================
    // Constants
    // ============================================================================================

    /// @notice Exit router allowed to set the proceeds receiver
    address public immutable EXIT_ROUTER;

    /// @notice Lender contract
    ILender public immutable LENDER;

    /// @notice Dutch Desk contract
    IDutchDesk public immutable DUTCH_DESK;

    /// @notice Auction contract
    IAuction public immutable AUCTION;

    // ============================================================================================
    // Transient storage
    // ============================================================================================

    /// @notice Transaction-scoped withdrawal receiver. When set, the entire withdrawal is sent
    ///         directly to it and may exceed the Lender's idle liquidity
    address internal transient _proceedsReceiver;

    // ============================================================================================
    // Storage
    // ============================================================================================

    /// @notice Whether deposits are open to everyone
    bool public openDeposits;

    /// @notice Auction kicked by the last `forceFreeFunds`
    uint256 public pendingAuctionId;

    /// @notice Addresses allowed to deposit when openDeposits is false
    mapping(address => bool) public allowed;

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
    ) BaseHealthCheck(_asset, _name) {
        // Set Lender contract
        LENDER = ILender(_lender);
        require(LENDER.asset() == _asset, "!asset");

        // Set the exit router
        EXIT_ROUTER = _exitRouter;

        // Set Dutch Desk and Auction contracts
        DUTCH_DESK = IDutchDesk(LENDER.TROVE_MANAGER().dutch_desk());
        AUCTION = IAuction(DUTCH_DESK.auction());

        // Start with an auction id that was (likely) never kicked
        pendingAuctionId = type(uint256).max;

        // Max approve the Lender to pull the asset
        asset.forceApprove(_lender, type(uint256).max);
    }

    // ============================================================================================
    // Public view functions
    // ============================================================================================

    /// @inheritdoc BaseStrategy
    function availableDepositLimit(
        address _owner
    ) public view override returns (uint256) {
        return openDeposits || allowed[_owner] ? LENDER.maxDeposit(address(this)) : 0;
    }

    /// @inheritdoc BaseStrategy
    function availableWithdrawLimit(
        address /*_owner*/
    ) public view override returns (uint256) {
        // If a `_proceedsReceiver` is set, there is no limit
        if (_proceedsReceiver != address(0)) return type(uint256).max;

        // Otherwise only what can be withdrawn from idle liquidity
        return asset.balanceOf(address(this)) + asset.balanceOf(address(LENDER));
    }

    // ============================================================================================
    // Management functions
    // ============================================================================================

    /// @notice Force a withdrawal from the Lender
    /// @dev Only callable by management
    /// @dev Could trigger a collateral redemption, meaning assets will arrive asynchronously
    ///      and may create a loss on the collateral/asset conversion
    /// @dev Cannot be called while there is an active auction
    /// @param _amount The amount of asset to free
    /// @param _minOut Minimum amount of asset delivered atomically
    /// @return The actual amount of asset freed
    function forceFreeFunds(
        uint256 _amount,
        uint256 _minOut
    ) public onlyManagement returns (uint256) {
        // Make sure there is no active auction
        require(!AUCTION.is_active(pendingAuctionId), "!auction");

        // Cache the next auction id, in case the redemption kicks one
        uint256 _nextAuctionId = DUTCH_DESK.nonce();

        // Cap the amount to our max redeem
        uint256 _shares = _amount == type(uint256).max
            ? LENDER.maxRedeem(address(this))
            : Math.min(LENDER.previewWithdraw(_amount), LENDER.maxRedeem(address(this)));

        // Withdraw and potentially trigger a collateral redemption
        _amount = _shares > 0 ? LENDER.redeem(_shares, address(this), address(this)) : 0;

        // Make sure we got at least the minimum amount requested
        require(_amount >= _minOut, "shrekt");

        // Record the kicked auction
        if (DUTCH_DESK.nonce() > _nextAuctionId) pendingAuctionId = _nextAuctionId;

        // Emit event
        emit ForceFreeFunds(_amount);

        // Return the actual amount freed
        return _amount;
    }

    /// @notice Deploy any idle funds to the Lender
    /// @dev Only callable by management
    /// @param _amount The amount of asset to deploy
    /// @return The actual amount of asset deployed
    function deployIdleFunds(
        uint256 _amount
    ) external onlyManagement returns (uint256) {
        // Cap the amount by our idle balance
        _amount = Math.min(asset.balanceOf(address(this)), _amount);

        // Cap by our max deposit
        _amount = Math.min(_amount, LENDER.maxDeposit(address(this)));

        // Deposit
        if (_amount > 0) LENDER.deposit(_amount, address(this));

        // Emit event
        emit DeployIdleFunds(_amount);

        // Return the actual amount deployed
        return _amount;
    }

    /// @notice Open or close strategy deposits globally
    /// @dev If closed, only `allowed[_owner]` addresses can deposit
    /// @param _isOpen Whether deposits are open to everyone
    function setOpen(
        bool _isOpen
    ) external onlyManagement {
        openDeposits = _isOpen;
    }

    /// @notice Allow or disallow a specific address to deposit
    /// @param _address Address to allow or disallow
    /// @param _isAllowed Whether the address is allowed to deposit
    function setAllowed(
        address _address,
        bool _isAllowed
    ) external onlyManagement {
        allowed[_address] = _isAllowed;
    }

    // ============================================================================================
    // Proceeds receiver
    // ============================================================================================

    /// @notice Set the withdrawal receiver for the current transaction
    /// @dev Only callable by the exit router
    /// @dev The entire withdrawal is sent directly to the receiver, idle liquidity atomically and
    ///      the rest via a redemption auction, and is accounted as a loss on the withdrawal
    /// @param _receiver The address to receive the withdrawal
    function setProceedsReceiver(
        address _receiver
    ) external {
        require(msg.sender == EXIT_ROUTER, "!exitRouter");
        _proceedsReceiver = _receiver;
    }

    // ============================================================================================
    // Internal mutative functions
    // ============================================================================================

    /// @inheritdoc BaseStrategy
    function _deployFunds(
        uint256 _amount
    ) internal override {
        LENDER.deposit(_amount, address(this));
    }

    /// @inheritdoc BaseStrategy
    function _freeFunds(
        uint256 _amount
    ) internal override {
        // Withdraw and potentially trigger a collateral redemption.
        // If `_proceedsReceiver` is set, the full withdrawal is delivered to it, with any
        // shortfall beyond the Lender's idle liquidity redeemed via a collateral auction
        LENDER.redeem(LENDER.convertToShares(_amount), _proceedsReceiver == address(0) ? address(this) : _proceedsReceiver, address(this));
    }

    /// @inheritdoc BaseStrategy
    function _harvestAndReport() internal view virtual override returns (uint256) {
        // Wait for our auction to be settled
        require(!AUCTION.is_active(pendingAuctionId), "!auction");

        // Total assets is whatever idle asset we have + our Lender shares converted to asset
        return asset.balanceOf(address(this)) + LENDER.convertToAssets(LENDER.balanceOf(address(this)));
    }

    /// @inheritdoc BaseStrategy
    function _emergencyWithdraw(
        uint256 _amount
    ) internal override {
        // Cap the amount to our max redeem
        uint256 _shares = _amount == type(uint256).max
            ? LENDER.maxRedeem(address(this))
            : Math.min(LENDER.previewWithdraw(_amount), LENDER.maxRedeem(address(this)));

        // Withdraw everything we can, trigger a collateral redemption if needed
        LENDER.redeem(_shares, address(this), address(this));
    }

}
