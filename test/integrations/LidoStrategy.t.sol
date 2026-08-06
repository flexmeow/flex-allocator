// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LidoFlexLenderStrategy} from "../../src/integrations/LidoStrategy.sol";

import {ILidoQueue} from "../interfaces/ILidoQueue.sol";
import {IStETH} from "../interfaces/IStETH.sol";

import "./CooldownBase.sol";

contract LidoStrategyTests is CooldownStrategyTests {

    LidoFlexLenderStrategy public lidoStrategy;

    // Tokens
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address public constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    // wstETH/WETH Morpho oracle
    address public constant MORPHO_ORACLE = 0xbD60A6770b27E084E8617335ddE769241B0e71D8;

    function setUp() public override {
        Base.setUp();

        // Keep the queued stETH under Lido's 1000 stETH per-request cap
        minFuzzAmount = 1 ether;
        maxFuzzAmount = 900 ether;
    }

    // ============================================================================================
    // Deployment hooks
    // ============================================================================================

    /// @dev Deploy a local v2 wstETH/WETH market
    function _deployLender() internal override returns (address) {
        address _priceOracle = deployCode("lib/flex-contracts/out/morpho_oracle.vy/morpho_oracle.json", abi.encode(MORPHO_ORACLE, WETH, WSTETH));
        return deployFlexMarket(WETH, WSTETH, _priceOracle, 0.1e18); // 0.1 WETH minimum debt
    }

    /// @dev Deploy the Lido strategy wrapping the local market's Lender
    function _deployStrategy() internal override returns (IStrategy) {
        lidoStrategy = new LidoFlexLenderStrategy(address(LENDER), address(exitRouter), "Flex wstETH/WETH Lender");
        cooldownStrategy = ICooldownStrategy(address(lidoStrategy));
        IStrategy _strategy = IStrategy(address(lidoStrategy));
        _strategy.setKeeper(keeper);
        _strategy.setPerformanceFeeRecipient(performanceFeeRecipient);
        _strategy.setPendingManagement(management);
        return _strategy;
    }

    // ============================================================================================
    // Tests
    // ============================================================================================

    function test_setup() public view {
        assertEq(address(lidoStrategy.COLLATERAL()), WSTETH, "E0");
        assertEq(address(lidoStrategy.STETH()), STETH, "E1");
        assertEq(lidoStrategy.pendingRedemptions(), 0, "E2");
        assertEq(address(asset), WETH, "E3");
        assertEq(address(LENDER.TROVE_MANAGER().collateral_token()), WSTETH, "E4");
    }

    function test_constructor_wrongAsset_reverts() public {
        // The live yvUSD/USDC Lender's asset is not WETH
        address _yvusdLender = 0xA967FcDb8a2bEF38caaB6131169c9D45be550Db0;
        vm.expectRevert("!asset");
        new LidoFlexLenderStrategy(_yvusdLender, address(exitRouter), "nope");
    }

    function test_initiateCooldown_accumulates(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        uint256 _loose = _freeInKind(_amount);

        // Queue two withdrawal requests, the pending amount accumulates
        vm.startPrank(management);
        uint256 _firstId = lidoStrategy.initiateCooldown(_loose / 2);
        uint256 _firstPending = lidoStrategy.pendingRedemptions();
        uint256 _secondId = lidoStrategy.initiateCooldown(type(uint256).max);
        vm.stopPrank();

        assertGt(_firstPending, 0, "E0");
        assertGt(_secondId, _firstId, "E1");
        assertGt(lidoStrategy.pendingRedemptions(), _firstPending, "E2");
        assertEq(ERC20(WSTETH).balanceOf(address(strategy)), 0, "E3");

        // The queued stETH is worth ~ the freed amount (1:1 redemption)
        assertApproxEqRel(lidoStrategy.pendingRedemptions(), _amount, 1e16, "E4"); // 1%
    }

    function test_claimCooldown(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        _freeInKind(_amount);

        // Queue the withdrawal
        vm.prank(management);
        uint256 _requestId = lidoStrategy.initiateCooldown(type(uint256).max);
        uint256 _pending = lidoStrategy.pendingRedemptions();
        assertGt(_pending, 0, "E0");

        // Finalize the request as Lido
        _finalizeLidoRequest(_requestId);

        // Claim the withdrawal
        uint256 _balanceBefore = asset.balanceOf(address(strategy));
        vm.prank(management);
        uint256 _claimed = lidoStrategy.claimCooldown(_requestId);

        assertEq(asset.balanceOf(address(strategy)), _balanceBefore + _claimed, "E1");
        assertApproxEqRel(_claimed, _pending, 1e15, "E2"); // 0.1%
        assertEq(lidoStrategy.pendingRedemptions(), 0, "E3");
        assertEq(lidoStrategy.requestAmounts(_requestId), 0, "E4");
    }

    function test_initiateCooldown_wrongCaller(
        address _wrongCaller
    ) public {
        vm.assume(_wrongCaller != management);
        vm.prank(_wrongCaller);
        vm.expectRevert("!management");
        lidoStrategy.initiateCooldown(1);
    }

    function test_claimCooldown_unknownRequest_reverts(
        uint256 _requestId
    ) public {
        vm.prank(management);
        vm.expectRevert("!request");
        lidoStrategy.claimCooldown(_requestId);
    }

    function test_claimCooldown_wrongCaller(
        address _wrongCaller
    ) public {
        vm.assume(_wrongCaller != management);
        vm.prank(_wrongCaller);
        vm.expectRevert("!management");
        lidoStrategy.claimCooldown(1);
    }

    function test_swapWsteth(
        uint256 _amount
    ) public {
        _amount = bound(_amount, minFuzzAmount, maxFuzzAmount);

        uint256 _loose = _freeInKind(_amount);
        assertGt(_loose, 0, "E0");

        // Swap the loose wstETH to the asset through Curve, skipping the queue
        uint256 _balanceBefore = asset.balanceOf(address(strategy));
        vm.prank(management);
        uint256 _swapped = lidoStrategy.swapWsteth(type(uint256).max, 0);

        assertEq(ERC20(WSTETH).balanceOf(address(strategy)), 0, "E1");
        assertEq(asset.balanceOf(address(strategy)), _balanceBefore + _swapped, "E2");
        assertApproxEqRel(_swapped, _amount, 1e16, "E3"); // 1%
        assertEq(lidoStrategy.pendingRedemptions(), 0, "E4");
    }

    function test_swapWsteth_wrongCaller(
        address _wrongCaller
    ) public {
        vm.assume(_wrongCaller != management);
        vm.prank(_wrongCaller);
        vm.expectRevert("!management");
        lidoStrategy.swapWsteth(1, 0);
    }

    // ============================================================================================
    // Helpers
    // ============================================================================================

    /// @dev Finalize a Lido withdrawal request by pranking the stETH contract
    function _finalizeLidoRequest(
        uint256 _requestId
    ) internal {
        ILidoQueue _queue = ILidoQueue(address(lidoStrategy.WITHDRAWAL_QUEUE()));
        uint256 _maxShareRate = IStETH(STETH).getPooledEthByShares(1e27);

        // Compute the ETH needed to finalize everything up to our request
        uint256[] memory _batches = new uint256[](1);
        _batches[0] = _requestId;
        (uint256 _ethToLock,) = _queue.prefinalize(_batches, _maxShareRate);

        // Finalize as Lido
        vm.deal(STETH, STETH.balance + _ethToLock);
        vm.prank(STETH);
        _queue.finalize{value: _ethToLock}(_requestId, _maxShareRate);
    }

}
