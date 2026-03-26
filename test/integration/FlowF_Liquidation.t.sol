// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {BalanceLedger} from "../../src/core/BalanceLedger.sol";
import {RiskModule} from "../../src/core/RiskModule.sol";
import {LiquidationEngine} from "../../src/core/LiquidationEngine.sol";
import {AssetBehaviorRegistry} from "../../src/core/AssetBehaviorRegistry.sol";
import {MarketScheduleRegistry} from "../../src/core/MarketScheduleRegistry.sol";
import {IBalanceLedger} from "../../src/interfaces/IBalanceLedger.sol";
import {IAssetBehaviorRegistry} from "../../src/interfaces/IAssetBehaviorRegistry.sol";
import {ILiquidationEngine} from "../../src/interfaces/ILiquidationEngine.sol";
import {MockToken} from "../../src/mocks/MockToken.sol";
import {MockChainlinkFeed} from "../../src/mocks/MockChainlinkFeed.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @title FlowF_Liquidation
/// @notice Integration test: deposit collateral → record debt → price drop → HF < 1.0 → liquidate
contract FlowF_LiquidationTest is Test {
    BalanceLedger public ledger;
    RiskModule public riskModule;
    LiquidationEngine public engine;
    AssetBehaviorRegistry public registry;
    MarketScheduleRegistry public scheduleRegistry;

    MockToken public usdc;
    MockToken public weth;
    MockChainlinkFeed public wethFeed;

    address public owner = address(0x1);
    address public borrower = address(0x10);
    address public liquidator = address(0x30);

    uint256 constant ARBITRUM_CHAIN_ID = 42161;

    function setUp() public {
        // Deploy tokens and oracle
        usdc = new MockToken("USD Coin", "USDC", 6, 0);
        weth = new MockToken("Wrapped Ether", "WETH", 18, 0);
        wethFeed = new MockChainlinkFeed(8, "WETH/USD");

        // Deploy all core contracts behind proxies
        vm.warp(100000);

        scheduleRegistry = MarketScheduleRegistry(address(new TransparentUpgradeableProxy(
            address(new MarketScheduleRegistry()), owner,
            abi.encodeCall(MarketScheduleRegistry.initialize, (owner))
        )));

        registry = AssetBehaviorRegistry(address(new TransparentUpgradeableProxy(
            address(new AssetBehaviorRegistry()), owner,
            abi.encodeCall(AssetBehaviorRegistry.initialize, (owner))
        )));

        ledger = BalanceLedger(address(new TransparentUpgradeableProxy(
            address(new BalanceLedger()), owner,
            abi.encodeCall(BalanceLedger.initialize, (owner))
        )));

        riskModule = RiskModule(address(new TransparentUpgradeableProxy(
            address(new RiskModule()), owner,
            abi.encodeCall(RiskModule.initialize, (owner, address(ledger), address(registry)))
        )));

        engine = LiquidationEngine(address(new TransparentUpgradeableProxy(
            address(new LiquidationEngine()), owner,
            abi.encodeCall(LiquidationEngine.initialize, (owner, address(ledger), address(riskModule), address(registry)))
        )));

        // Wire up — sequential timelocks
        vm.startPrank(owner);

        // 1. AssetBehaviorRegistry: set schedule registry + propose WETH
        registry.proposeMarketScheduleRegistry(address(scheduleRegistry));
        vm.warp(100000 + 48 hours + 1);
        registry.applyMarketScheduleRegistry();
        registry.proposeAsset(address(weth), _wethBehavior());

        // 2. BalanceLedger writers: engine, riskModule, test contract
        ledger.proposeAuthorizedWriter(address(engine), true);
        vm.warp(100000 + 48 hours + 1);  // T1
        ledger.applyAuthorizedWriter();
        registry.executeAddAsset(address(weth));

        ledger.proposeAuthorizedWriter(address(riskModule), true);
        vm.warp(100000 + 96 hours + 2);  // T2
        ledger.applyAuthorizedWriter();

        ledger.proposeAuthorizedWriter(address(this), true);
        vm.warp(100000 + 144 hours + 3); // T3
        ledger.applyAuthorizedWriter();

        // 3. RiskModule: authorize engine + test (now timelocked)
        riskModule.proposeAuthorizedCaller(address(engine), true);
        vm.warp(100000 + 192 hours + 4);
        riskModule.applyAuthorizedCaller();
        riskModule.proposeAuthorizedCaller(address(this), true);
        vm.warp(100000 + 240 hours + 5);
        riskModule.applyAuthorizedCaller();

        // 4. BalanceLedger: set risk module (timelocked)
        ledger.proposeAdminChange("riskModule", address(riskModule));
        vm.warp(100000 + 288 hours + 6);
        ledger.applyAdminChange("riskModule");

        // 5. LiquidationEngine: authorize test for grace period (timelocked)
        engine.proposeAuthorizedCallerChange(address(this), true);
        vm.warp(100000 + 336 hours + 7);
        engine.applyAuthorizedCallerChange(address(this));

        vm.stopPrank();

        // Refresh oracle price at current timestamp so isPriceFresh passes
        wethFeed.setPrice(3000e8); // $3,000 per WETH

        // CRIT-01 FIX: Liquidator must have debt asset balance to pay for liquidation.
        // Seed the liquidator with USDC in BalanceLedger.
        vm.startPrank(owner);
        ledger.proposeAuthorizedWriter(address(this), true);
        vm.warp(100000 + 288 hours + 6);
        ledger.applyAuthorizedWriter();
        vm.stopPrank();
        // Credit liquidator with ample USDC balance for debt repayment
        ledger.credit(liquidator, address(usdc), 100_000e18);
        // Refresh price again after warp
        wethFeed.setPrice(3000e8);
    }

    // ============ Helpers ============

    function _wethBehavior() internal view returns (IAssetBehaviorRegistry.AssetBehavior memory) {
        return IAssetBehaviorRegistry.AssetBehavior({
            assetClass: IAssetBehaviorRegistry.AssetClass.D,
            yieldMechanism: IAssetBehaviorRegistry.YieldMechanism.NONE,
            deployToExternalProtocol: false,
            preferredYieldProtocol: address(0),
            trackByShares: false,
            trackBySharePrice: false,
            priceFeed: address(wethFeed),
            maxStaleness: 3600,
            minPrice: 0,
            maxPrice: 0,
            secondaryPriceFeed: address(0),
            secondaryMaxStaleness: 0,
            maxLTV: 8000,
            liquidationThreshold: 8500,
            hasMarketHours: false,
            marketSchedule: bytes32(0),
            afterHoursLTVBuffer: 0,
            liquidationBonusBPS: 500,
            spokeMode: IAssetBehaviorRegistry.SpokeIntegrationMode.HUB_NATIVE,
            requiresIssuerWhitelist: false,
            hasIssuerBlocklist: false,
            distributionPolicy: IAssetBehaviorRegistry.DistributionPolicy.PASS_THROUGH,
            trustedDistributionSender: address(0),
            supplyCap: 0,
            debtCeiling: 0,
            minBorrowAmount: 0,
            lendable: false,
            collateralEligible: true,
            active: true
        });
    }

    function _setupUndercollateralizedPosition() internal {
        // 1. Add 1 WETH as collateral ($3000)
        ledger.addCollateral(borrower, address(weth), 1e18, ARBITRUM_CHAIN_ID);

        // 2. Set cached USD value for HF computation
        // HF = (3000 * 0.85) / debt. For HF < 1.0, need debt > 2550
        ledger.updateCollateralUsdValue(borrower, address(weth), 3000e18);

        // 3. Record debt of 2800e18 → HF = 2550/2800 = 0.91 < 1.0
        riskModule.recordUserDebt(borrower, 2800e18);
        riskModule.recordDebtAgainstAsset(address(weth), 2800e18);
    }

    // ============ Tests ============

    /// @notice Full liquidation lifecycle: undercollateralized → liquidated
    function test_flowF_liquidation_lifecycle() public {
        _setupUndercollateralizedPosition();

        // Verify position is undercollateralized
        uint256 hf = riskModule.getHealthFactor(borrower);
        assertLt(hf, 1e18, "HF should be below 1.0");

        // Liquidator covers 50% of debt = 1400e18
        uint256 debtToCover = 1400e18;

        // Get collateral before
        IBalanceLedger.CollateralPosition memory posBefore = ledger.getCollateralByAsset(borrower, address(weth));
        uint256 collateralBefore = posBefore.amount;

        // Execute liquidation
        vm.prank(liquidator);
        engine.liquidate(borrower, address(usdc), debtToCover, address(weth));

        // Verify collateral was reduced
        IBalanceLedger.CollateralPosition memory posAfter = ledger.getCollateralByAsset(borrower, address(weth));
        assertLt(posAfter.amount, collateralBefore, "Collateral should be reduced");

        // Verify debt was reduced
        uint256 remainingDebt = riskModule.getTotalDebtUSD(borrower);
        assertEq(remainingDebt, 2800e18 - debtToCover, "Debt should be reduced by debtToCover");
    }

    /// @notice Healthy position → reverts with PositionHealthy
    function test_flowF_liquidation_reverts_healthy() public {
        // Add 1 WETH at $3000
        ledger.addCollateral(borrower, address(weth), 1e18, ARBITRUM_CHAIN_ID);
        ledger.updateCollateralUsdValue(borrower, address(weth), 3000e18);

        // Record small debt: HF = (3000*0.85)/1000 = 2.55 > 1.0
        riskModule.recordUserDebt(borrower, 1000e18);
        riskModule.recordDebtAgainstAsset(address(weth), 1000e18);

        uint256 hf = riskModule.getHealthFactor(borrower);
        assertGt(hf, 1e18, "HF should be above 1.0");

        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(ILiquidationEngine.PositionHealthy.selector, hf));
        engine.liquidate(borrower, address(usdc), 500e18, address(weth));
    }

    /// @notice Grace period blocks liquidation until expired
    function test_flowF_grace_period_enforcement() public {
        _setupUndercollateralizedPosition();

        // Set 6-hour grace period
        bytes32 positionId = keccak256(abi.encode(borrower, address(usdc)));
        engine.setGracePeriod(positionId, 6, 0, 1600);

        // Liquidation reverts during grace period
        vm.prank(liquidator);
        vm.expectRevert(); // GracePeriodNotExpired
        engine.liquidate(borrower, address(usdc), 1400e18, address(weth));

        // Warp past grace period
        vm.warp(block.timestamp + 7 hours);
        wethFeed.setPrice(3000e8); // refresh feed after warp

        // Now liquidation succeeds
        vm.prank(liquidator);
        engine.liquidate(borrower, address(usdc), 1400e18, address(weth));
    }

    /// @notice Stale oracle blocks liquidation
    function test_flowF_stale_oracle_reverts() public {
        _setupUndercollateralizedPosition();

        // Make feed stale
        wethFeed.setStale(7200); // 2 hours ago, maxStaleness = 3600

        vm.prank(liquidator);
        vm.expectRevert(ILiquidationEngine.PriceFeedStale.selector);
        engine.liquidate(borrower, address(usdc), 1400e18, address(weth));
    }
}
