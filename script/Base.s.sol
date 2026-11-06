// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ICentralAPROracle} from "./interfaces/ICentralAPROracle.sol";
import {ICommonReportTrigger} from "./interfaces/ICommonReportTrigger.sol";

import {StrategyFactory} from "../src/StrategyFactory.sol";

import "forge-std/Script.sol";

abstract contract BaseScript is Script {

    // Deployer
    address public constant DEPLOYER = 0x000005281a2b04A182085D37cC9E6dD552795caa; // johnny.flexmeow.eth

    // Yearn addresses
    address public constant SMS = 0x16388463d60FFE0661Cf7F1f31a7D658aC790ff7; // sms mainnet
    address public constant KEEPER = 0x604e586F17cE106B64185A7a0d2c1Da5bAce711E; // yHaaS mainnet
    address public constant ACCOUNTANT = 0x5A74Cb32D36f2f517DB6f7b0A0591e09b22cDE69; // accountant mainnet

    // Vaults
    address public constant YVUSDC1 = 0xBe53A109B494E5c9f97b9Cd39Fe969BE68BF6204; // yvUSDC-1 mainnet
    address public constant YVWETH1 = 0xc56413869c6CDf96496f2b1eF801fEDBdFA7dDB0; // yvWETH-1 mainnet
    address public constant YVFLEXUSDC = 0x863687e4E9751b57F38b4B0ebA04744C72d0f7B8; // yvFlexUSDC mainnet
    address public constant YVFLEXWETH = 0xfaC55fAFD0b55BFb8dD41F735EfCc195adA9891F; // yvFlexWETH mainnet

    // Deployed contracts
    address public constant EXIT_ROUTER = 0xe8a511403B0C83e7b85513e00Ed39996B48c2aeD;
    address public constant FIXED_REPORT_TRIGGER = 0xb9F57B62Cbe9463da16E5b75e3B809321a0eA871;
    address public constant STRATEGY_APR_ORACLE = 0xcB5A60AB76F3741204C87744ECFe0445C74Eb171;
    ICentralAPROracle public constant CENTRAL_APR_ORACLE = ICentralAPROracle(0x1981AD9F44F2EA9aDd2dC4AD7D075c102C70aF92);
    ICommonReportTrigger public constant COMMON_REPORT_TRIGGER = ICommonReportTrigger(0xf8dF17a35c88AbB25e83C92f9D293B4368b9D52D);
    StrategyFactory public constant STRATEGY_FACTORY = StrategyFactory(0x1792348Fe3ebDdc0C6bB123aC24c094ac9D78252);

    /// @notice Load the deployer's private key, making sure it's johnny.flexmeow.eth
    function _deployerKey() internal view returns (uint256 _pk) {
        _pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        require(vm.addr(_pk) == DEPLOYER, "!johnny.flexmeow.eth");
        console.log("Deployer address: %s", DEPLOYER);
    }

}
