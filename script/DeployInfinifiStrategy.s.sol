// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IStrategy} from "../src/interfaces/IStrategy.sol";

import {InfinifiFlexLenderStrategy} from "../src/integrations/InfinifiStrategy.sol";

import "./Base.s.sol";

// ---- Usage ----

// deploy:
// forge script script/DeployInfinifiStrategy.s.sol:DeployInfinifiStrategy --verify --slow --etherscan-api-key $KEY --rpc-url $RPC_URL --broadcast

contract DeployInfinifiStrategy is BaseScript {

    // Market params
    string public constant NAME = "Flex siUSD/USDC Lender";
    address public constant LENDER = 0xd3E15f39A381620c1400cEBd06CF92AD100E0071; // Flex v2 siUSD/USDC Lender
    address public constant VAULT = YVUSDC1;

    function run() public {
        vm.startBroadcast(_deployerKey());

        // Deploy a Strategy for yvUSDC-1, and one for InfiniFi whose depositor is allowed once known
        address _vaultStrategy = _deployStrategy(VAULT);
        address _infinifiStrategy = _deployStrategy(address(0));

        console2.log("---------------------------------");
        console2.log("yvUSDC-1 Strategy: ", _vaultStrategy);
        console2.log("InfiniFi Strategy: ", _infinifiStrategy);
        console2.log("---------------------------------");

        vm.stopBroadcast();
    }

    function _deployStrategy(
        address _depositor
    ) internal returns (address) {
        // Deploy the Strategy. The deployer is management, keeper, and fee recipient until set below
        IStrategy _strategy = IStrategy(address(new InfinifiFlexLenderStrategy(LENDER, EXIT_ROUTER, NAME)));

        // Set up the Strategy
        _strategy.setKeeper(KEEPER);
        _strategy.setPerformanceFeeRecipient(ACCOUNTANT);
        _strategy.setProfitMaxUnlockTime(0 days);
        if (_depositor != address(0)) _strategy.setAllowed(_depositor, true);
        _strategy.setPerformanceFee(0);
        _strategy.setPendingManagement(SMS);

        // Set APR oracle for the strategy
        CENTRAL_APR_ORACLE.setOracle(address(_strategy), STRATEGY_APR_ORACLE);

        // Set report trigger for the strategy
        COMMON_REPORT_TRIGGER.setCustomStrategyTrigger(address(_strategy), FIXED_REPORT_TRIGGER);

        return address(_strategy);
    }

}
