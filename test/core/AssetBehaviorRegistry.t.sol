// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AssetBehaviorRegistry} from "../../src/core/AssetBehaviorRegistry.sol";
import {IAssetBehaviorRegistry} from "../../src/interfaces/IAssetBehaviorRegistry.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @notice Mock MarketScheduleRegistry for after-hours LTV tests
contract MockMarketScheduleRegistry {
    bool public mockIsOpen = true;

    function setIsOpen(bool isOpen_) external {
        mockIsOpen = isOpen_;
    }

    function isOpen(bytes32) external view returns (bool) {
        return mockIsOpen;
    }
}

contract AssetBehaviorRegistryTest is Test {
    AssetBehaviorRegistry public registry;
    MockMarketScheduleRegistry public mockSchedule;

    address public owner = address(0x1);
    address public usdc = address(0x100);
    address public ousg = address(0x200);
    address public stock = address(0x300);
    address public liquidator1 = address(0x400);

    function setUp() public {
        AssetBehaviorRegistry impl = new AssetBehaviorRegistry();
        bytes memory initData = abi.encodeCall(AssetBehaviorRegistry.initialize, (owner));
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(impl), owner, initData
        );
        registry = AssetBehaviorRegistry(address(proxy));

        mockSchedule = new MockMarketScheduleRegistry();

        vm.prank(owner);
        registry.setMarketScheduleRegistry(address(mockSchedule));
    }

    // ============ Helper ============

    function _usdcBehavior() internal pure returns (IAssetBehaviorRegistry.AssetBehavior memory) {
        return IAssetBehaviorRegistry.AssetBehavior({
            assetClass: IAssetBehaviorRegistry.AssetClass.C,
            yieldMechanism: IAssetBehaviorRegistry.YieldMechanism.NONE,
            deployToExternalProtocol: true,
            preferredYieldProtocol: address(0),
            trackByShares: false,
            trackBySharePrice: false,
            priceFeed: address(0),
            maxStaleness: 3600,
            maxLTV: 8000,
            liquidationThreshold: 8500,
            hasMarketHours: false,
            marketSchedule: bytes32(0),
            afterHoursLTVBuffer: 0,
            liquidationBonusBPS: 500,
            spokeMode: IAssetBehaviorRegistry.SpokeIntegrationMode.BRIDGE_CCTP,
            requiresIssuerWhitelist: false,
            hasIssuerBlocklist: false,
            distributionPolicy: IAssetBehaviorRegistry.DistributionPolicy.PASS_THROUGH,
            trustedDistributionSender: address(0),
            supplyCap: 0,
            debtCeiling: 0,
            minBorrowAmount: 500e6,
            lendable: true,
            collateralEligible: true,
            active: true
        });
    }

    function _stockBehavior() internal pure returns (IAssetBehaviorRegistry.AssetBehavior memory) {
        return IAssetBehaviorRegistry.AssetBehavior({
            assetClass: IAssetBehaviorRegistry.AssetClass.D,
            yieldMechanism: IAssetBehaviorRegistry.YieldMechanism.NONE,
            deployToExternalProtocol: false,
            preferredYieldProtocol: address(0),
            trackByShares: false,
            trackBySharePrice: false,
            priceFeed: address(0),
            maxStaleness: 1800,
            maxLTV: 5000,
            liquidationThreshold: 5700,
            hasMarketHours: true,
            marketSchedule: keccak256("NYSE"),
            afterHoursLTVBuffer: 1000,
            liquidationBonusBPS: 1200,
            spokeMode: IAssetBehaviorRegistry.SpokeIntegrationMode.ATTESTATION,
            requiresIssuerWhitelist: true,
            hasIssuerBlocklist: true,
            distributionPolicy: IAssetBehaviorRegistry.DistributionPolicy.PASS_THROUGH,
            trustedDistributionSender: address(0),
            supplyCap: 0,
            debtCeiling: 1_000_000e18,
            minBorrowAmount: 200e18,
            lendable: false,
            collateralEligible: true,
            active: true
        });
    }

    // ============ Helper: propose + execute asset (with timelock warp) ============

    function _proposeAndAddAsset(address asset, IAssetBehaviorRegistry.AssetBehavior memory behavior) internal {
        vm.prank(owner);
        registry.proposeAsset(asset, behavior);
        vm.warp(block.timestamp + 48 hours + 1);
        vm.prank(owner);
        registry.executeAddAsset(asset);
    }

    // ============ addAsset Tests ============

    function test_addAsset_classC() public {
        _proposeAndAddAsset(usdc, _usdcBehavior());

        IAssetBehaviorRegistry.AssetBehavior memory b = registry.getBehavior(usdc);
        assertTrue(b.active);
        assertTrue(b.assetClass == IAssetBehaviorRegistry.AssetClass.C);
        assertEq(b.maxLTV, 8000);
        assertEq(b.liquidationThreshold, 8500);
        assertTrue(b.deployToExternalProtocol);
        assertTrue(b.lendable);
        assertTrue(b.collateralEligible);
    }

    function test_addAsset_classD_stock() public {
        _proposeAndAddAsset(stock, _stockBehavior());

        IAssetBehaviorRegistry.AssetBehavior memory b = registry.getBehavior(stock);
        assertTrue(b.assetClass == IAssetBehaviorRegistry.AssetClass.D);
        assertTrue(b.hasMarketHours);
        assertEq(b.afterHoursLTVBuffer, 1000);
        assertEq(b.liquidationBonusBPS, 1200);
        assertEq(b.debtCeiling, 1_000_000e18);
        assertFalse(b.lendable);
    }

    function test_addAsset_reverts_duplicate() public {
        _proposeAndAddAsset(usdc, _usdcBehavior());

        // Proposing a duplicate should revert
        vm.prank(owner);
        vm.expectRevert(IAssetBehaviorRegistry.AssetAlreadyExists.selector);
        registry.proposeAsset(usdc, _usdcBehavior());
    }

    function test_addAsset_reverts_non_owner() public {
        vm.prank(address(0x999));
        vm.expectRevert(); // OwnableUnauthorizedAccount
        registry.proposeAsset(usdc, _usdcBehavior());
    }

    function test_addAsset_reverts_excessive_bonus() public {
        IAssetBehaviorRegistry.AssetBehavior memory b = _usdcBehavior();
        b.liquidationBonusBPS = 2500; // > 2000 max

        vm.prank(owner);
        vm.expectRevert(IAssetBehaviorRegistry.MaxLiquidationBonusExceeded.selector);
        registry.proposeAsset(usdc, b);
    }

    function test_addAsset_reverts_invalid_ltv() public {
        IAssetBehaviorRegistry.AssetBehavior memory b = _usdcBehavior();
        b.maxLTV = 9000;
        b.liquidationThreshold = 8000; // threshold < LTV is invalid

        vm.prank(owner);
        vm.expectRevert(IAssetBehaviorRegistry.InvalidLiquidationThreshold.selector);
        registry.proposeAsset(usdc, b);
    }

    function test_addAsset_requires_timelock() public {
        vm.prank(owner);
        registry.proposeAsset(usdc, _usdcBehavior());

        // Cannot execute before timelock
        vm.prank(owner);
        vm.expectRevert(IAssetBehaviorRegistry.TimelockNotExpired.selector);
        registry.executeAddAsset(usdc);

        // Can execute after timelock
        vm.warp(block.timestamp + 48 hours + 1);
        vm.prank(owner);
        registry.executeAddAsset(usdc);

        assertTrue(registry.getBehavior(usdc).active);
    }

    // ============ Deactivate / Pause Tests ============

    function test_deactivateAsset() public {
        _proposeAndAddAsset(usdc, _usdcBehavior());

        vm.prank(owner);
        registry.deactivateAsset(usdc);

        IAssetBehaviorRegistry.AssetBehavior memory b = registry.getBehavior(usdc);
        assertFalse(b.active);
    }

    function test_pauseAsset() public {
        _proposeAndAddAsset(usdc, _usdcBehavior());

        vm.prank(owner);
        registry.pauseAsset(usdc);
        assertTrue(registry.isAssetPaused(usdc));
    }

    function test_unpauseAsset_requires_timelock() public {
        _proposeAndAddAsset(usdc, _usdcBehavior());

        // Update to set _lastUpdateAt
        vm.warp(block.timestamp + 48 hours + 1);
        vm.prank(owner);
        registry.updateAsset(usdc, _usdcBehavior());

        vm.prank(owner);
        registry.pauseAsset(usdc);

        // Unpause should revert before timelock expires
        vm.prank(owner);
        vm.expectRevert(IAssetBehaviorRegistry.TimelockNotExpired.selector);
        registry.unpauseAsset(usdc);

        // After timelock
        vm.warp(block.timestamp + 48 hours + 1);
        vm.prank(owner);
        registry.unpauseAsset(usdc);
        assertFalse(registry.isAssetPaused(usdc));
    }

    // ============ LTV Governance Tests ============

    function test_updateAsset_creates_pending_ltv_change() public {
        _proposeAndAddAsset(usdc, _usdcBehavior());

        // Prepare updated behavior with different LTV
        IAssetBehaviorRegistry.AssetBehavior memory updated = _usdcBehavior();
        updated.maxLTV = 7500;
        updated.liquidationThreshold = 8000;

        vm.warp(block.timestamp + 48 hours + 1); // pass initial timelock
        vm.prank(owner);
        registry.updateAsset(usdc, updated);

        IAssetBehaviorRegistry.LTVChange memory change = registry.getPendingLTVChange(usdc);
        assertEq(change.newMaxLTV, 7500);
        assertEq(change.newLiqThreshold, 8000);
        assertFalse(change.appliedToExisting);
    }

    function test_applyLTVToExisting_requires_30_day_observation() public {
        _proposeAndAddAsset(usdc, _usdcBehavior());

        IAssetBehaviorRegistry.AssetBehavior memory updated = _usdcBehavior();
        updated.maxLTV = 7500;
        updated.liquidationThreshold = 8000;

        vm.warp(block.timestamp + 48 hours + 1);
        vm.prank(owner);
        registry.updateAsset(usdc, updated);

        // Before 30 days
        vm.prank(owner);
        vm.expectRevert(IAssetBehaviorRegistry.ObservationPeriodNotComplete.selector);
        registry.applyLTVToExisting(usdc);

        // After 30 days
        vm.warp(block.timestamp + 30 days + 1);
        vm.prank(owner);
        registry.applyLTVToExisting(usdc);

        IAssetBehaviorRegistry.AssetBehavior memory b = registry.getBehavior(usdc);
        assertEq(b.maxLTV, 7500);
    }

    // ============ Effective LTV with Market Hours ============

    function test_effectiveLiqThreshold_market_open() public {
        _proposeAndAddAsset(stock, _stockBehavior());

        mockSchedule.setIsOpen(true);
        assertEq(registry.getEffectiveLiqThreshold(stock), 5700); // full threshold
    }

    function test_effectiveLiqThreshold_market_closed() public {
        _proposeAndAddAsset(stock, _stockBehavior());

        mockSchedule.setIsOpen(false);
        // 5700 - 1000 (afterHoursLTVBuffer) = 4700
        assertEq(registry.getEffectiveLiqThreshold(stock), 4700);
    }

    function test_effectiveMaxLTV_market_closed() public {
        _proposeAndAddAsset(stock, _stockBehavior());

        mockSchedule.setIsOpen(false);
        // 5000 - 1000 = 4000
        assertEq(registry.getEffectiveMaxLTV(stock), 4000);
    }

    function test_no_market_hours_asset_unaffected() public {
        _proposeAndAddAsset(usdc, _usdcBehavior());

        mockSchedule.setIsOpen(false); // doesn't matter for USDC
        assertEq(registry.getEffectiveLiqThreshold(usdc), 8500); // unchanged
    }

    // ============ Liquidator Whitelist Tests ============

    function test_liquidator_whitelist_empty_allows_anyone() public {
        _proposeAndAddAsset(usdc, _usdcBehavior());

        assertTrue(registry.isLiquidatorApproved(usdc, liquidator1));
        assertTrue(registry.isLiquidatorApproved(usdc, address(0x999)));
    }

    function test_liquidator_whitelist_restricts() public {
        vm.prank(owner);
        registry.addAsset(ousg, _usdcBehavior());

        vm.prank(owner);
        registry.addLiquidator(ousg, liquidator1);

        assertTrue(registry.isLiquidatorApproved(ousg, liquidator1));
        assertFalse(registry.isLiquidatorApproved(ousg, address(0x999)));
    }

    function test_liquidator_remove() public {
        vm.prank(owner);
        registry.addAsset(ousg, _usdcBehavior());

        vm.prank(owner);
        registry.addLiquidator(ousg, liquidator1);

        vm.prank(owner);
        registry.removeLiquidator(ousg, liquidator1);

        assertFalse(registry.isLiquidatorApproved(ousg, liquidator1));
    }

    // ============ Timelock Enforcement (Security Invariant #7) ============

    function test_updateAsset_respects_timelock() public {
        _proposeAndAddAsset(usdc, _usdcBehavior());

        // First update to set _lastUpdateAt
        vm.warp(block.timestamp + 48 hours + 1);
        vm.prank(owner);
        registry.updateAsset(usdc, _usdcBehavior());

        // Second update immediately should fail
        vm.prank(owner);
        vm.expectRevert(IAssetBehaviorRegistry.TimelockNotExpired.selector);
        registry.updateAsset(usdc, _usdcBehavior());

        // After timelock, should succeed
        vm.warp(block.timestamp + 48 hours + 1);
        vm.prank(owner);
        registry.updateAsset(usdc, _usdcBehavior());
    }
}
