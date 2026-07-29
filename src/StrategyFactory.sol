// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.30;

import {IStrategy} from "./interfaces/IStrategy.sol";

import {FlexLenderStrategy as Strategy} from "./Strategy.sol";

/// @title Strategy Factory
/// @author Flex
/// @notice Deploys new Flex Lender Strategy vaults
contract StrategyFactory {

    // ============================================================================================
    // Constants
    // ============================================================================================

    /// @notice Exit router every deployed Strategy uses
    address public immutable EXIT_ROUTER;

    // ============================================================================================
    // Constructor
    // ============================================================================================

    /// @notice Constructor
    /// @param _exitRouter The address of the exit router
    constructor(
        address _exitRouter
    ) {
        EXIT_ROUTER = _exitRouter;
    }

    // ============================================================================================
    // Deploy
    // ============================================================================================

    /// @notice Deploy a new Flex Lender Strategy contract
    /// @param _asset The address of the borrow token
    /// @param _lender The address of the Lender contract
    /// @param _management The address of the Strategy management
    /// @param _keeper The address of the Strategy keeper
    /// @param _performanceFeeRecipient The address that receives performance fees from the Strategy
    /// @param _name The name of the strategy
    /// @return The address of the newly deployed Strategy contract
    function deploy(
        address _asset,
        address _lender,
        address _management,
        address _keeper,
        address _performanceFeeRecipient,
        string calldata _name
    ) external returns (address) {
        // Deploy the Strategy contract
        IStrategy _strategy = IStrategy(address(new Strategy(_asset, _lender, EXIT_ROUTER, _name)));

        // Configure Strategy roles
        _strategy.setKeeper(_keeper);
        _strategy.setPendingManagement(_management);
        _strategy.setPerformanceFeeRecipient(_performanceFeeRecipient);

        // Return the address of the new Strategy
        return address(_strategy);
    }

}
