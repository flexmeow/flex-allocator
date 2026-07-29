// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {StrategyFactory} from "../src/StrategyFactory.sol";
import {FlexExitRouter} from "../src/periphery/ExitRouter.sol";

import "forge-std/Script.sol";

// ---- Usage ----

// deploy:
// forge script script/DeployStrategyFactory.s.sol:DeployStrategyFactory --verify --slow --etherscan-api-key $KEY --rpc-url $RPC_URL --broadcast

contract DeployStrategyFactory is Script {

    bool public isTest;
    address public deployerAddress;

    // Deployed contracts
    FlexExitRouter public exitRouter;
    StrategyFactory public strategyFactory;

    function run() public {
        uint256 _pk = isTest ? 42_069 : vm.envUint("DEPLOYER_PRIVATE_KEY");

        // Derive deployer address from private key
        deployerAddress = vm.addr(_pk);

        if (!isTest) {
            require(deployerAddress == address(0x000005281a2b04A182085D37cC9E6dD552795caa), "!johnny.flexmeow.eth");
            console.log("Deployer address: %s", deployerAddress);
        }

        vm.startBroadcast(_pk);

        // Deploy the ExitRouter and the StrategyFactory
        exitRouter = new FlexExitRouter();
        strategyFactory = new StrategyFactory(address(exitRouter));

        if (isTest) {
            vm.label({account: address(exitRouter), newLabel: "ExitRouter"});
            vm.label({account: address(strategyFactory), newLabel: "StrategyFactory"});
        } else {
            console2.log("---------------------------------");
            console2.log("Exit Router: ", address(exitRouter));
            console2.log("Strategy Factory: ", address(strategyFactory));
            console2.log("---------------------------------");
        }

        vm.stopBroadcast();
    }

}
