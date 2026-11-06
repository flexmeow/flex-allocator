// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IStrategy} from "../src/interfaces/IStrategy.sol";

import {LidoFlexLenderStrategy} from "../src/integrations/LidoStrategy.sol";

import "./Base.s.sol";

// ---- Usage ----

// deploy:
// forge script script/DeployLidoStrategy.s.sol:DeployLidoStrategy --verify --slow --etherscan-api-key $KEY --rpc-url $RPC_URL --broadcast

contract DeployLidoStrategy is BaseScript {

    // Market params
    string public constant NAME = "Flex wstETH/WETH Lender";
    address public constant LENDER = 0xa411c4D26EF24e8A727F1cdeeabf85F1fA50498D; // Flex v2 wstETH/WETH Lender

    function run() public {
        vm.startBroadcast(_deployerKey());

        // Deploy a Strategy for yvFlexWETH, and one for yvWETH-1
        address _yvFlexWethStrategy = _deployStrategy(YVFLEXWETH);
        address _yvWeth1Strategy = _deployStrategy(YVWETH1);

        console2.log("---------------------------------");
        console2.log("yvFlexWETH Strategy: ", _yvFlexWethStrategy);
        console2.log("yvWETH-1 Strategy: ", _yvWeth1Strategy);
        console2.log("---------------------------------");

        vm.stopBroadcast();
    }

    function _deployStrategy(
        address _vault
    ) internal returns (address) {
        // Deploy the Strategy. The deployer is management, keeper, and fee recipient until set below
        IStrategy _strategy = IStrategy(address(new LidoFlexLenderStrategy(LENDER, EXIT_ROUTER, NAME)));

        // Set up the Strategy
        _strategy.setKeeper(KEEPER);
        _strategy.setPerformanceFeeRecipient(ACCOUNTANT);
        _strategy.setProfitMaxUnlockTime(0 days);
        _strategy.setAllowed(_vault, true);
        _strategy.setPerformanceFee(0);
        _strategy.setPendingManagement(SMS);

        // Set APR oracle for the strategy
        CENTRAL_APR_ORACLE.setOracle(address(_strategy), STRATEGY_APR_ORACLE);

        // Set report trigger for the strategy
        COMMON_REPORT_TRIGGER.setCustomStrategyTrigger(address(_strategy), FIXED_REPORT_TRIGGER);

        return address(_strategy);
    }

}
