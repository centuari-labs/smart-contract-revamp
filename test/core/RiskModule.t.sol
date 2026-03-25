// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {RiskModule} from "../../src/core/RiskModule.sol";
import {BalanceLedger} from "../../src/core/BalanceLedger.sol";
import {AssetBehaviorRegistry} from "../../src/core/AssetBehaviorRegistry.sol";
import {MarketScheduleRegistry} from "../../src/core/MarketScheduleRegistry.sol";
import {MockChainlinkFeed} from "../../src/mocks/MockChainlinkFeed.sol";
import {IAssetBehaviorRegistry} from "../../src/interfaces/IAssetBehaviorRegistry.sol";
import {IBalanceLedger} from "../../src/interfaces/IBalanceLedger.sol";
import {IMarketScheduleRegistry} from "../../src/interfaces/IMarketScheduleRegistry.sol";
import {IRiskModule} from "../../src/interfaces/IRiskModule.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract RiskModuleTest is Test {
    RiskModule public riskModule;
    BalanceLedger public ledger;
    AssetBehaviorRegistry public registry;
    MarketScheduleRegistry public scheduleRegistry;
    MockChainlinkFeed public usdcFeed;
    MockChainlinkFeed public ousgFeed;
    MockChainlinkFeed public stockFeed;

    address public owner = address(0x1);
    address public authorized = address(0x2);
    address public user1 = address(0x10);
    address public usdc = address(0x100);
    address public ousg = address(0x200);
    address public stock = address(0x300);

    function setUp() public {
        // Deploy all contracts via proxies
        ledger = BalanceLedger(address(new TransparentUpgradeableProxy(
            address(new BalanceLedger()), owner,
            abi.encodeCall(BalanceLedger.initialize, (owner))
        )));

        registry = AssetBehaviorRegistry(address(new TransparentUpgradeableProxy(
            address(new AssetBehaviorRegistry()), owner,
            abi.encodeCall(AssetBehaviorRegistry.initialize, (owner))
        )));

        scheduleRegistry = MarketScheduleRegistry(address(new TransparentUpgradeableProxy(
            address(new MarketScheduleRegistry()), owner,
            abi.encodeCall(MarketScheduleRegistry.initialize, (owner))
        )));

        riskModule = RiskModule(address(new TransparentUpgradeableProxy(
            address(new RiskModule()), owner,
            abi.encodeCall(RiskModule.initialize, (owner, address(ledger), address(registry)))
        )));

        // Deploy price feeds
        usdcFeed = new MockChainlinkFeed(8, "USDC/USD");
        ousgFeed = new MockChainlinkFeed(8, "OUSG/USD");
        stockFeed = new MockChainlinkFeed(8, "STOCK/USD");

        // Set prices
        usdcFeed.setPrice(1e8);   // $1.00
        ousgFeed.setPrice(100e8); // $100.00
        stockFeed.setPrice(50e8); // $50.00

        // Configure registries
        vm.warp(1);
        vm.startPrank(owner);
        registry.setMarketScheduleRegistry(address(scheduleRegistry));

        // Add USDC (Class C, lendable, collateral) — via propose/execute timelock
        registry.proposeAsset(usdc, _behavior(
            IAssetBehaviorRegistry.AssetClass.C, 8000, 8500, false, 0, 500, address(usdcFeed), 0, 500e6
        ));
        registry.proposeAsset(ousg, _behavior(
            IAssetBehaviorRegistry.AssetClass.A, 5500, 6200, false, 0, 800, address(ousgFeed), 5_000_000e18, 0
        ));
        _addNYSESchedule();
        registry.proposeAsset(stock, _behavior(
            IAssetBehaviorRegistry.AssetClass.D, 5000, 5700, true, 1000, 1200, address(stockFeed), 1_000_000e18, 0
        ));

        // Warp past 48h timelock and execute all
        vm.warp(1 + 48 hours + 1);
        registry.executeAddAsset(usdc);
        registry.executeAddAsset(ousg);
        registry.executeAddAsset(stock);

        // Authorize the risk module + authorized caller
        ledger.proposeAuthorizedWriter(authorized, true);
        vm.warp(1 + 96 hours + 2);
        ledger.applyAuthorizedWriter();
        ledger.setRiskModule(address(riskModule));
        riskModule.proposeAuthorizedCaller(authorized, true);
        vm.warp(1 + 144 hours + 3);
        riskModule.applyAuthorizedCaller();

        vm.stopPrank();

        // Refresh feeds at current timestamp so isPriceFresh returns true
        usdcFeed.setPrice(1e8);
        ousgFeed.setPrice(100e8);
        stockFeed.setPrice(50e8);
    }

    // ============ Helpers ============

    function _behavior(
        IAssetBehaviorRegistry.AssetClass class_,
        uint256 maxLTV,
        uint256 liqThreshold,
        bool hasMarketHours,
        uint256 afterHoursBuffer,
        uint256 liquidationBonus,
        address priceFeed,
        uint256 debtCeiling,
        uint256 minBorrowAmount
    ) internal pure returns (IAssetBehaviorRegistry.AssetBehavior memory) {
        return IAssetBehaviorRegistry.AssetBehavior({
            assetClass: class_,
            yieldMechanism: IAssetBehaviorRegistry.YieldMechanism.NONE,
            deployToExternalProtocol: class_ == IAssetBehaviorRegistry.AssetClass.C,
            preferredYieldProtocol: address(0),
            trackByShares: false,
            trackBySharePrice: false,
            priceFeed: priceFeed,
            maxStaleness: 3600,
            maxLTV: maxLTV,
            liquidationThreshold: liqThreshold,
            hasMarketHours: hasMarketHours,
            marketSchedule: hasMarketHours ? keccak256("NYSE") : bytes32(0),
            afterHoursLTVBuffer: afterHoursBuffer,
            liquidationBonusBPS: liquidationBonus,
            spokeMode: IAssetBehaviorRegistry.SpokeIntegrationMode.HUB_NATIVE,
            requiresIssuerWhitelist: false,
            hasIssuerBlocklist: false,
            distributionPolicy: IAssetBehaviorRegistry.DistributionPolicy.PASS_THROUGH,
            trustedDistributionSender: address(0),
            supplyCap: 0,
            debtCeiling: debtCeiling,
            minBorrowAmount: minBorrowAmount,
            lendable: class_ == IAssetBehaviorRegistry.AssetClass.C,
            collateralEligible: true,
            active: true
        });
    }

    function _addNYSESchedule() internal {
        uint8[] memory tradingDays = new uint8[](5);
        for (uint8 i = 0; i < 5; i++) tradingDays[i] = i + 1;

        scheduleRegistry.addSchedule(
            keccak256("NYSE"),
            IMarketScheduleRegistry.MarketSchedule({
                exchangeId: "NYSE",
                openTimeUTC: 14 hours + 30 minutes,
                closeTimeUTC: 21 hours,
                tradingDays: tradingDays,
                holidays: new uint256[](0)
            })
        );
    }

    function _setupCollateral(address user, address asset, uint256 amount, uint256 usdValue) internal {
        vm.prank(authorized);
        ledger.addCollateral(user, asset, amount, 42161); // Arbitrum chainId

        // Update cached USD value via direct storage manipulation (since we don't have a keeper mock)
        // In production, CollateralRegistry would update this
        IBalanceLedger.CollateralPosition[] memory positions = ledger.getCollateral(user);
        // For test: we need to set usdValueCached. Since BalanceLedger doesn't expose a setter,
        // we'll add collateral and trust the mock setup. The RiskModule reads usdValueCached.
        // For this test, we set up a separate view of the collateral value.
    }

    // ============ Health Factor Tests ============

    function test_healthFactor_no_debt() public view {
        uint256 hf = riskModule.getHealthFactor(user1);
        assertEq(hf, type(uint256).max); // No debt = infinite HF
    }

    function test_healthFactor_with_debt() public {
        // Give user some debt
        vm.prank(authorized);
        riskModule.recordUserDebt(user1, 10_000e18); // $10,000 debt

        // Add USDC collateral (done via addCollateral, but usdValueCached is 0 by default)
        // In real flow, CollateralRegistry updates usdValueCached via keeper
        // HF with 0 collateral and 10k debt = 0
        uint256 hf = riskModule.getHealthFactor(user1);
        assertEq(hf, 0); // No collateral cached value
    }

    function test_getTotalDebtUSD() public {
        vm.prank(authorized);
        riskModule.recordUserDebt(user1, 5_000e18);

        assertEq(riskModule.getTotalDebtUSD(user1), 5_000e18);

        vm.prank(authorized);
        riskModule.reduceUserDebt(user1, 2_000e18);

        assertEq(riskModule.getTotalDebtUSD(user1), 3_000e18);
    }

    // ============ Borrow Validation Tests ============

    function test_validateBorrow_below_min_borrow() public {
        // USDC has minBorrowAmount = 500e6
        address[] memory collaterals = new address[](1);
        collaterals[0] = usdc;

        // Enable USDC as collateral for user
        vm.prank(authorized);
        ledger.addCollateral(user1, usdc, 10_000e6, 42161);

        (bool valid, string memory reason) = riskModule.validateBorrow(
            user1, usdc, 100e6, collaterals // 100 USDC < 500 USDC min
        );
        assertFalse(valid);
        assertEq(reason, "BELOW_MIN_BORROW_AMOUNT");
    }

    function test_validateBorrow_debt_ceiling_exceeded() public {
        // OUSG has debtCeiling = 5M
        address[] memory collaterals = new address[](1);
        collaterals[0] = ousg;

        vm.prank(authorized);
        ledger.addCollateral(user1, ousg, 100e18, 42161);

        // Record existing debt near ceiling
        vm.prank(authorized);
        riskModule.recordDebtAgainstAsset(ousg, 4_900_000e18);

        (bool valid, string memory reason) = riskModule.validateBorrow(
            user1, usdc, 200_000e18, collaterals // pushes over 5M ceiling
        );
        assertFalse(valid);
        assertEq(reason, "DEBT_CEILING_EXCEEDED");
    }

    function test_validateBorrow_collateral_not_enabled() public {
        address[] memory collaterals = new address[](1);
        collaterals[0] = ousg;

        // Don't enable OUSG as collateral
        vm.prank(user1);
        ledger.setAsCollateral(ousg, false);

        (bool valid, string memory reason) = riskModule.validateBorrow(
            user1, usdc, 1000e18, collaterals
        );
        assertFalse(valid);
        assertEq(reason, "COLLATERAL_NOT_ENABLED");
    }

    // ============ Debt Tracking Tests ============

    function test_recordDebtAgainstAsset() public {
        vm.prank(authorized);
        riskModule.recordDebtAgainstAsset(ousg, 1_000_000e18);

        assertEq(riskModule.getTotalDebtAgainstAsset(ousg), 1_000_000e18);
    }

    function test_reduceDebtAgainstAsset() public {
        vm.prank(authorized);
        riskModule.recordDebtAgainstAsset(ousg, 1_000_000e18);

        vm.prank(authorized);
        riskModule.reduceDebtAgainstAsset(ousg, 400_000e18);

        assertEq(riskModule.getTotalDebtAgainstAsset(ousg), 600_000e18);
    }

    function test_debt_recording_unauthorized() public {
        vm.prank(user1);
        vm.expectRevert(IRiskModule.Unauthorized.selector);
        riskModule.recordDebtAgainstAsset(ousg, 1_000_000e18);
    }

    // ============ Price Feed Tests ============

    function test_getAssetPriceUSD() public view {
        (uint256 price, uint256 updatedAt) = riskModule.getAssetPriceUSD(usdc);
        assertEq(price, 1e18); // $1.00 in 18 decimals
        assertGt(updatedAt, 0);
    }

    function test_isPriceFresh_true() public view {
        assertTrue(riskModule.isPriceFresh(usdc));
    }

    function test_isPriceFresh_false() public {
        usdcFeed.setStale(7200); // 2 hours stale, maxStaleness = 3600
        assertFalse(riskModule.isPriceFresh(usdc));
    }

    // ============ Effective LTV Tests ============

    function test_effectiveLTV_delegates_to_registry() public view {
        assertEq(riskModule.getEffectiveMaxLTV(usdc), 8000);
        assertEq(riskModule.getEffectiveLiqThreshold(usdc), 8500);
    }

    function test_effectiveLTV_market_hours_stock() public {
        // Set to a known Wednesday at 16:00 UTC (during NYSE hours: 14:30-21:00 UTC)
        uint256 jan7_2026 = 1736208000; // Jan 7 2026 00:00 UTC (Wednesday)
        vm.warp(jan7_2026 + 16 hours);

        // During market hours: full LTV
        assertEq(riskModule.getEffectiveMaxLTV(stock), 5000);
        assertEq(riskModule.getEffectiveLiqThreshold(stock), 5700);

        // After hours: reduced by afterHoursLTVBuffer (1000 BPS)
        vm.warp(jan7_2026 + 22 hours);
        assertEq(riskModule.getEffectiveMaxLTV(stock), 4000);
        assertEq(riskModule.getEffectiveLiqThreshold(stock), 4700);
    }
}
