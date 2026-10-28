// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IStrategy} from "../src/interfaces/IStrategy.sol";

import {LockedYvusdFlexLenderStrategy} from "../src/integrations/LockedYvusdStrategy.sol";

import "./Base.s.sol";

// ---- Usage ----

// deploy:
// forge script script/DeployLockedYvusdStrategy.s.sol:DeployLockedYvusdStrategy --verify --slow --etherscan-api-key $KEY --rpc-url $RPC_URL --broadcast

contract DeployLockedYvusdStrategy is BaseScript {

    // Market params
    string public constant NAME = "Flex Locked yvUSD/USDC Lender";
    address public constant LENDER = address(0); // TODO: Flex v2 Locked yvUSD/USDC Lender
    address public constant VAULT = YVFLEXUSDC;

    function run() public {
        require(LENDER != address(0), "!lender");

        vm.startBroadcast(_deployerKey());

        // Deploy the Strategy. The deployer is management, keeper, and fee recipient until set below
        IStrategy _strategy = IStrategy(address(new LockedYvusdFlexLenderStrategy(LENDER, EXIT_ROUTER, NAME)));

        // Set up the Strategy
        _strategy.setKeeper(KEEPER);
        _strategy.setPerformanceFeeRecipient(ACCOUNTANT);
        _strategy.setProfitMaxUnlockTime(0 days);
        _strategy.setAllowed(VAULT, true);
        _strategy.setPerformanceFee(0);
        _strategy.setPendingManagement(SMS);

        // Set APR oracle for the strategy
        CENTRAL_APR_ORACLE.setOracle(address(_strategy), STRATEGY_APR_ORACLE);

        // Set report trigger for the strategy
        COMMON_REPORT_TRIGGER.setCustomStrategyTrigger(address(_strategy), FIXED_REPORT_TRIGGER);

        console2.log("---------------------------------");
        console2.log("Strategy: ", address(_strategy));
        console2.log("---------------------------------");

        vm.stopBroadcast();
    }

}
