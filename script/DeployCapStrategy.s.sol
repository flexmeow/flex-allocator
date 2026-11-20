// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IStrategy} from "../src/interfaces/IStrategy.sol";

import {IVault} from "./interfaces/IVault.sol";
import {IVaultFactory} from "./interfaces/IVaultFactory.sol";

import "./Base.s.sol";

// ---- Usage ----

// deploy:
// forge script script/DeployCapStrategy.s.sol:DeployCapStrategy --verify --slow --etherscan-api-key $KEY --rpc-url $RPC_URL --broadcast

contract DeployCapStrategy is BaseScript {

    // Market params
    string public constant NAME = "Flex stcUSD/USDC Lender";
    address public constant ASSET = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // USDC
    address public constant LENDER = 0x25E69d5256b7c47541C203d2324BE2CD0898b507; // Flex v2 stcUSD/USDC Lender

    // Vault params
    string private constant VAULT_NAME = "Flex Cap USDC yVault";
    string private constant VAULT_SYMBOL = "yvFlexCapUSDC";

    // 3.0.4 Vault Factory
    IVaultFactory private constant VAULT_FACTORY = IVaultFactory(0x770D0d1Fb036483Ed4AbB6d53c1C88fb277D812F);

    function run() public {
        vm.startBroadcast(_deployerKey());

        // Deploy the Cap ecosystem vault
        IVault _vault = IVault(VAULT_FACTORY.deploy_new_vault(ASSET, VAULT_NAME, VAULT_SYMBOL, DEPLOYER, 4 days));
        _vault.set_role(DEPLOYER, 16383); // ADD_STRATEGY_MANAGER/DEPOSIT_LIMIT_MANAGER/MAX_DEBT_MANAGER/DEBT_MANAGER
        _vault.set_role(SMS, 16383); // ADD_STRATEGY_MANAGER/DEPOSIT_LIMIT_MANAGER/MAX_DEBT_MANAGER/DEBT_MANAGER
        _vault.set_role(KEEPER, 32); // REPORTING_MANAGER
        _vault.set_deposit_limit(100_000_000_000 ether); // 100 billion
        _vault.set_auto_allocate(true);

        // Deploy a Strategy for the new vault, and one for yvUSDC-1
        address _vaultStrategy = _deployStrategy(address(_vault));
        address _yvUsdc1Strategy = _deployStrategy(YVUSDC1);

        // Add the new vault's Strategy to it
        _vault.add_strategy(_vaultStrategy);
        _vault.update_max_debt_for_strategy(_vaultStrategy, 10_000_000_000 ether); // 10 billion

        // Hand the vault over to SMS
        _vault.transfer_role_manager(SMS);
        _vault.set_role(DEPLOYER, 0);

        console2.log("---------------------------------");
        console2.log("Vault: ", address(_vault));
        console2.log("yvFlexCapUSDC Strategy: ", _vaultStrategy);
        console2.log("yvUSDC-1 Strategy: ", _yvUsdc1Strategy);
        console2.log("---------------------------------");

        vm.stopBroadcast();
    }

    function _deployStrategy(
        address _vault
    ) internal returns (address) {
        // Deploy the Strategy
        IStrategy _strategy = IStrategy(STRATEGY_FACTORY.deploy(ASSET, LENDER, DEPLOYER, KEEPER, ACCOUNTANT, NAME));

        // Set up the Strategy
        _strategy.acceptManagement();
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
