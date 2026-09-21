// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {ICentralAPROracle} from "./interfaces/ICentralAPROracle.sol";
import {ICommonReportTrigger} from "./interfaces/ICommonReportTrigger.sol";

import {AvantFlexLenderStrategy} from "../src/integrations/AvantStrategy.sol";

import "forge-std/Script.sol";

// ---- Usage ----

// deploy:
// forge script script/DeployAvantStrategy.s.sol:DeployAvantStrategy --verify --slow --etherscan-api-key $KEY --rpc-url $RPC_URL --broadcast

contract DeployAvantStrategy is Script {

    // Market params
    string public constant NAME = "Flex savETH/WETH Lender";
    address public constant LENDER = address(0); // TODO: Flex v2 savETH/WETH Lender

    // Yearn addresses
    address public constant SMS = 0x16388463d60FFE0661Cf7F1f31a7D658aC790ff7; // sms mainnet
    address public constant VAULT = 0xfaC55fAFD0b55BFb8dD41F735EfCc195adA9891F; // yvFlexWETH mainnet
    address public constant KEEPER = 0x604e586F17cE106B64185A7a0d2c1Da5bAce711E; // yHaaS mainnet
    address public constant ACCOUNTANT = 0x5A74Cb32D36f2f517DB6f7b0A0591e09b22cDE69; // accountant mainnet

    // Deployed contracts
    address public constant EXIT_ROUTER = 0xe8a511403B0C83e7b85513e00Ed39996B48c2aeD;
    address public constant FIXED_REPORT_TRIGGER = 0xb9F57B62Cbe9463da16E5b75e3B809321a0eA871;
    address public constant STRATEGY_APR_ORACLE = 0xcB5A60AB76F3741204C87744ECFe0445C74Eb171;
    ICentralAPROracle public constant CENTRAL_APR_ORACLE = ICentralAPROracle(0x1981AD9F44F2EA9aDd2dC4AD7D075c102C70aF92);
    ICommonReportTrigger public constant COMMON_REPORT_TRIGGER = ICommonReportTrigger(0xf8dF17a35c88AbB25e83C92f9D293B4368b9D52D);

    function run() public {
        uint256 _pk = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // Derive deployer address from private key
        address _deployerAddress = vm.addr(_pk);

        require(_deployerAddress == address(0x000005281a2b04A182085D37cC9E6dD552795caa), "!johnny.flexmeow.eth");
        require(LENDER != address(0), "!lender");
        console.log("Deployer address: %s", _deployerAddress);

        vm.startBroadcast(_pk);

        // Deploy the Strategy. The deployer is management, keeper, and fee recipient until set below
        IStrategy _strategy = IStrategy(address(new AvantFlexLenderStrategy(LENDER, EXIT_ROUTER, NAME)));

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
