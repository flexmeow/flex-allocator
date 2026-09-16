// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IVault} from "./interfaces/IVault.sol";
import {IVaultFactory} from "./interfaces/IVaultFactory.sol";

import "forge-std/Script.sol";

// ---- Usage ----

// deploy:
// forge script script/DeployVault.s.sol:DeployVault --verify --slow --etherscan-api-key $KEY --rpc-url $RPC_URL --broadcast

contract DeployVault is Script {

    string private constant NAME = "Flex WETH yVault";
    string private constant SYMBOL = "yvFlexWETH";
    address private constant ASSET = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH
    address private constant SMS = 0x16388463d60FFE0661Cf7F1f31a7D658aC790ff7; // sms mainnet
    address private constant KEEPER = 0x604e586F17cE106B64185A7a0d2c1Da5bAce711E; // yHaaS mainnet
    address private constant ROLE_MANAGER = 0xb3bd6B2E61753C311EFbCF0111f75D29706D9a41;

    // 3.1.0 Vault Factory
    IVaultFactory private constant VAULT_FACTORY = IVaultFactory(0x310aC28ACF5E514abDbFF9Ab25e21f1bfe22bcAC);

    function run() public {
        uint256 _pk = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // Derive deployer address from private key
        address _deployerAddress = vm.addr(_pk);

        require(_deployerAddress == address(0x000005281a2b04A182085D37cC9E6dD552795caa), "!johnny.flexmeow.eth");
        console.log("Deployer address: %s", _deployerAddress);

        vm.startBroadcast(_pk);

        IVault _vault = IVault(VAULT_FACTORY.deploy_new_vault(ASSET, NAME, SYMBOL, _deployerAddress, 4 days));
        _vault.set_role(_deployerAddress, 16383); // ADD_STRATEGY_MANAGER/DEPOSIT_LIMIT_MANAGER/MAX_DEBT_MANAGER/DEBT_MANAGER
        _vault.set_role(SMS, 16383); // ADD_STRATEGY_MANAGER/DEPOSIT_LIMIT_MANAGER/MAX_DEBT_MANAGER/DEBT_MANAGER
        _vault.set_role(KEEPER, 32); // REPORTING_MANAGER
        _vault.set_deposit_limit(100_000_000_000 ether); // 100 billion
        _vault.set_auto_allocate(true);
        // for (uint256 i = 0; i < strategies.length; i++) {
        //     _vault.add_strategy(strategies[i]);
        //     _vault.update_max_debt_for_strategy(strategies[i], 10_000_000_000 ether); // 10 billion
        // }
        _vault.transfer_role_manager(SMS);
        _vault.set_role(_deployerAddress, 0);

        console2.log("---------------------------------");
        console2.log("Vault: ", address(_vault));
        console2.log("---------------------------------");

        vm.stopBroadcast();
    }

}
