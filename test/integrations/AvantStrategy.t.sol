// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMorphoOracleFactory} from "../interfaces/IMorphoOracleFactory.sol";

import {AvantFlexLenderStrategy} from "../../src/integrations/AvantStrategy.sol";
import {IStakedAvant} from "../../src/interfaces/IStakedAvant.sol";

import "./CooldownBase.sol";

contract AvantStrategyTests is CooldownStrategyTests {

    AvantFlexLenderStrategy public avantStrategy;

    // Tokens
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant AVETH = 0x9469470C9878bf3d6d0604831d9A3A366156f7EE;
    address public constant SAVETH = 0xDA06eE2dACF9245Aa80072a4407deBDea0D7e341;

    // Avant minting contract
    address public constant AVANT_MINTING = 0x09becF6E5e297825D19aA14eD6081A03524532D7;

    // savETH/WETH Morpho oracle factory
    address public constant MORPHO_ORACLE_FACTORY = 0x3A7bB36Ee3f3eE32A60e9f2b33c1e5f2E83ad766;

    event DelegatedSignerInitiated(address indexed signer, address indexed delegator);

    function setUp() public override {
        Base.setUp();

        // Stay within savETH's avETH backing
        minFuzzAmount = 1 ether;
        maxFuzzAmount = 500 ether;
    }

    // ============================================================================================
    // Deployment hooks
    // ============================================================================================

    /// @dev Deploy a local v2 savETH/WETH market
    function _deployLender() internal override returns (address) {
        // savETH/WETH price oracle (vault conversion only, avETH assumed 1:1 with WETH)
        address _morphoOracle = IMorphoOracleFactory(MORPHO_ORACLE_FACTORY)
            .createMorphoChainlinkOracleV2(
                SAVETH, // baseVault: savETH
                1e18, // baseVaultConversionSample
                address(0), // baseFeed1
                address(0), // baseFeed2
                18, // baseTokenDecimals: avETH
                address(0), // quoteVault
                1, // quoteVaultConversionSample
                address(0), // quoteFeed1
                address(0), // quoteFeed2
                18, // quoteTokenDecimals: WETH
                bytes32(uint256(420)) // salt, a salt 0 oracle already exists
            );
        address _priceOracle = deployCode("lib/flex-contracts/out/morpho_oracle.vy/morpho_oracle.json", abi.encode(_morphoOracle, WETH, SAVETH));

        return deployFlexMarket(WETH, SAVETH, _priceOracle, 0.1e18); // 0.1 WETH minimum debt
    }

    /// @dev Deploy the Avant strategy wrapping the local market's Lender
    function _deployStrategy() internal override returns (IStrategy) {
        avantStrategy = new AvantFlexLenderStrategy(address(LENDER), address(exitRouter), "Flex savETH/WETH Lender");
        cooldownStrategy = ICooldownStrategy(address(avantStrategy));
        IStrategy _strategy = IStrategy(address(avantStrategy));
        _strategy.setKeeper(keeper);
        _strategy.setPerformanceFeeRecipient(performanceFeeRecipient);
        _strategy.setPendingManagement(management);
        return _strategy;
    }

    // ============================================================================================
    // Tests
    // ============================================================================================

    function test_setup() public view {
        assertEq(address(avantStrategy.COLLATERAL()), SAVETH, "E0");
        assertEq(address(avantStrategy.AVETH()), AVETH, "E1");
        assertEq(avantStrategy.pendingRedemptions(), 0, "E2");
        assertEq(address(asset), WETH, "E3");
        assertEq(address(LENDER.TROVE_MANAGER().collateral_token()), SAVETH, "E4");
        assertEq(ERC20(AVETH).allowance(address(avantStrategy), AVANT_MINTING), type(uint256).max, "E5");
    }

    function test_constructor_wrongCollateral_reverts() public {
        // The live yvWETH-2/WETH Lender's collateral does not unstake to avETH
        address _yvwethLender = 0x0d57098e501D68905fC4B0A3397f7D4Aa4889E36;
        vm.expectRevert("!aveth");
        new AvantFlexLenderStrategy(_yvwethLender, address(exitRouter), "nope");
    }

    function test_constructor_startingPriceBuffer_reverts() public {
        // A market with a starting price buffer cannot be wrapped. Reuse the existing oracle, the
        // Morpho oracle factory reverts on a same-salt redeploy
        startingPriceBuffer = 1e18 + 1e15; // 100.1%
        address _oracle = ITroveManager(address(LENDER.TROVE_MANAGER())).price_oracle();
        address _lender = deployFlexMarket(WETH, SAVETH, _oracle, 0.1e18);
        vm.expectRevert("!buffer");
        new AvantFlexLenderStrategy(_lender, address(exitRouter), "nope");
    }

    function test_initiateCooldown(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        uint256 _loose = _freeInKind(_amount);

        // Start cooling all the loose savETH
        vm.prank(management);
        uint256 _cooling = avantStrategy.initiateCooldown(type(uint256).max);

        // The shares are gone into the silo, their avETH value is cooling and pending
        assertGt(_loose, 0, "E0");
        assertEq(ERC20(SAVETH).balanceOf(address(strategy)), 0, "E1");
        (uint104 _cooldownEnd, uint152 _siloed) = IStakedAvant(SAVETH).cooldowns(address(strategy));
        assertEq(_siloed, _cooling, "E2");
        assertEq(_cooldownEnd, block.timestamp + IStakedAvant(SAVETH).cooldownDuration(), "E3");
        assertEq(avantStrategy.pendingRedemptions(), _cooling, "E4");
        assertApproxEqRel(_cooling, _amount, 1e16, "E5"); // 1%

        // Reports are blocked until the cooldown is claimed and redeemed
        vm.prank(keeper);
        vm.expectRevert("!cooldown");
        strategy.report();
    }

    function test_initiateCooldown_restarts(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        uint256 _loose = _freeInKind(_amount);
        uint256 _cooldownDuration = IStakedAvant(SAVETH).cooldownDuration();

        // Cool half, wait half the cooldown, cool the rest. The whole amount restarts the timer
        vm.startPrank(management);
        uint256 _firstCooling = avantStrategy.initiateCooldown(_loose / 2);
        skip(_cooldownDuration / 2);
        uint256 _secondCooling = avantStrategy.initiateCooldown(type(uint256).max);
        vm.stopPrank();

        (uint104 _cooldownEnd, uint152 _siloed) = IStakedAvant(SAVETH).cooldowns(address(strategy));
        assertEq(_siloed, _firstCooling + _secondCooling, "E0");
        assertEq(_cooldownEnd, block.timestamp + _cooldownDuration, "E1");
        assertEq(avantStrategy.pendingRedemptions(), _siloed, "E2");
    }

    function test_claimCooldown(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        _freeInKind(_amount);

        vm.prank(management);
        uint256 _cooling = avantStrategy.initiateCooldown(type(uint256).max);

        // Wait out the cooldown and unstake
        skip(IStakedAvant(SAVETH).cooldownDuration() + 1);
        vm.prank(management);
        uint256 _avethOut = avantStrategy.claimCooldown();

        // The avETH is loose, still pending until Avant redeems it
        assertEq(_avethOut, _cooling, "E0");
        assertEq(ERC20(AVETH).balanceOf(address(strategy)), _avethOut, "E1");
        (, uint152 _siloed) = IStakedAvant(SAVETH).cooldowns(address(strategy));
        assertEq(_siloed, 0, "E2");
        assertEq(avantStrategy.pendingRedemptions(), _avethOut, "E3");
        vm.prank(keeper);
        vm.expectRevert("!cooldown");
        strategy.report();

        // Avant redeems the avETH for the asset 1:1, off-chain
        deal(AVETH, address(strategy), 0);
        airdrop(asset, address(strategy), _avethOut);
        assertEq(avantStrategy.pendingRedemptions(), 0, "E4");

        // Reporting works again. Allow a loss, since the in-kind take settled below par
        vm.prank(management);
        strategy.setLossLimitRatio(MAX_BPS - 1);
        vm.prank(keeper);
        strategy.report();
    }

    function test_claimCooldown_beforeCooldown_reverts(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        _freeInKind(_amount);

        vm.startPrank(management);
        avantStrategy.initiateCooldown(type(uint256).max);

        // Nothing is claimable before the cooldown ends
        vm.expectRevert("!claim");
        avantStrategy.claimCooldown();
        vm.stopPrank();
    }

    function test_claimCooldown_nothingCooling_reverts() public {
        vm.prank(management);
        vm.expectRevert("!claim");
        avantStrategy.claimCooldown();
    }

    function test_setDelegatedSigner(
        address _signer
    ) public {
        vm.assume(_signer != address(0));

        // The delegation is initiated on the minting contract, for the signer to confirm
        vm.expectEmit(true, true, false, false, AVANT_MINTING);
        emit DelegatedSignerInitiated(_signer, address(strategy));
        vm.prank(management);
        avantStrategy.setDelegatedSigner(_signer);
    }

    function test_setDelegatedSigner_wrongCaller(
        address _wrongCaller
    ) public {
        vm.assume(_wrongCaller != management);
        vm.prank(_wrongCaller);
        vm.expectRevert("!management");
        avantStrategy.setDelegatedSigner(management);
    }

    function test_initiateCooldown_wrongCaller(
        address _wrongCaller
    ) public {
        vm.assume(_wrongCaller != management);
        vm.prank(_wrongCaller);
        vm.expectRevert("!management");
        avantStrategy.initiateCooldown(1);
    }

    function test_claimCooldown_wrongCaller(
        address _wrongCaller
    ) public {
        vm.assume(_wrongCaller != management);
        vm.prank(_wrongCaller);
        vm.expectRevert("!management");
        avantStrategy.claimCooldown();
    }

}
