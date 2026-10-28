// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IStrategy} from "../src/interfaces/IStrategy.sol";

import "./Base.s.sol";

// ---- Usage ----

// deploy:
// forge script script/DeployStrategy.s.sol:DeployStrategy --verify --slow --etherscan-api-key $KEY --rpc-url $RPC_URL --broadcast

contract DeployStrategy is BaseScript {

    // Market params
    string public constant NAME = "Flex yvWETH-2/WETH Lender";
    address public constant ASSET = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH
    address public constant LENDER = 0x0d57098e501D68905fC4B0A3397f7D4Aa4889E36; // Flex v2 yvWETH-2/WETH Lender
    address public constant VAULT = YVFLEXWETH;

    function run() public {
        vm.startBroadcast(_deployerKey());

        // Deploy the Strategy
        IStrategy _strategy = IStrategy(STRATEGY_FACTORY.deploy(ASSET, LENDER, DEPLOYER, KEEPER, ACCOUNTANT, NAME));

        // Set up the Strategy
        _strategy.acceptManagement();
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
