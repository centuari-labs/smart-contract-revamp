// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LiquidationEngine} from "../../src/core/LiquidationEngine.sol";
import {ILiquidationEngine} from "../../src/interfaces/ILiquidationEngine.sol";
import {IRiskModule} from "../../src/interfaces/IRiskModule.sol";
import {IBalanceLedger} from "../../src/interfaces/IBalanceLedger.sol";
import {IAssetBehaviorRegistry} from "../../src/interfaces/IAssetBehaviorRegistry.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @notice Minimal mock RiskModule for liquidation tests
contract MockRiskModuleLiq {
    mapping(address => uint256) public mockHF;
    mapping(address => uint256) public mockDebt;
    mapping(address => bool) public mockFresh;
    mapping(address => uint256) public assetPrices;

    function setHF(address user, uint256 hf) external { mockHF[user] = hf; }
    function setDebt(address user, uint256 debt) external { mockDebt[user] = debt; }
    function setFresh(address asset, bool fresh) external { mockFresh[asset] = fresh; }
    function setAssetPrice(address asset, uint256 price) external { assetPrices[asset] = price; }

    function getHealthFactor(address user) external view returns (uint256) { return mockHF[user]; }
    function getTotalDebtUSD(address user) external view returns (uint256) { return mockDebt[user]; }
    function isPriceFresh(address asset) external view returns (bool) { return mockFresh[asset]; }
    function reduceUserDebt(address, uint256) external {}
    function reduceDebtAgainstAsset(address, uint256) external {}
    function getAssetPriceUSD(address asset) external view returns (uint256, uint256) {
        return (assetPrices[asset], block.timestamp);
    }
}

/// @notice Minimal mock BalanceLedger for liquidation tests
contract MockBalanceLedgerLiq {
    mapping(address => mapping(address => IBalanceLedger.CollateralPosition)) public positions;
    mapping(address => mapping(address => bool)) public isCollateral;

    function setPosition(address user, address asset, uint256 amount, uint256 usdValue) external {
        positions[user][asset] = IBalanceLedger.CollateralPosition({
            asset: asset,
            amount: amount,
            lockedShares: 0,
            lastAttestationTs: 0,
            usdValueCached: usdValue,
            sourceChainId: 42161,
            spokeVaultId: bytes32(0),
            state: IBalanceLedger.CollateralState.ACTIVE
        });
        isCollateral[user][asset] = true;
    }

    function getCollateralByAsset(address user, address asset)
        external view returns (IBalanceLedger.CollateralPosition memory)
    {
        return positions[user][asset];
    }

    function getIsUsedAsCollateral(address user, address asset) external view returns (bool) {
        return isCollateral[user][asset];
    }

    function reduceCollateral(address user, address asset, uint256 amount) external {
        positions[user][asset].amount -= amount;
    }

    function updateCollateralUsdValue(address user, address asset, uint256 newUsdValue) external {
        positions[user][asset].usdValueCached = newUsdValue;
    }

    // CRIT-01 FIX: LiquidationEngine now debits liquidator and credits collateral
    mapping(address => mapping(address => uint256)) public available;

    function setAvailable(address user, address asset, uint256 amount) external {
        available[user][asset] = amount;
    }

    function debit(address user, address asset, uint256 amount) external {
        require(available[user][asset] >= amount, "MockLedger: insufficient");
        available[user][asset] -= amount;
    }

    function addCollateral(address user, address asset, uint256 amount, uint256) external {
        positions[user][asset].amount += amount;
    }
}

/// @notice Minimal mock AssetBehaviorRegistry
contract MockAssetRegistryLiq {
    mapping(address => IAssetBehaviorRegistry.AssetBehavior) public behaviors;

    function setBehavior(address asset, uint256 bonusBPS) external {
        behaviors[asset].liquidationBonusBPS = bonusBPS;
        behaviors[asset].active = true;
        behaviors[asset].collateralEligible = true;
    }

    function getBehavior(address asset) external view returns (IAssetBehaviorRegistry.AssetBehavior memory) {
        return behaviors[asset];
    }

    function isLiquidatorApproved(address, address) external pure returns (bool) {
        return true; // open liquidation
    }
}

contract LiquidationEngineTest is Test {
    LiquidationEngine public engine;
    MockRiskModuleLiq public riskModule;
    MockBalanceLedgerLiq public ledger;
    MockAssetRegistryLiq public assetRegistry;

    address public owner = address(0x1);
    address public authorized = address(0x2);
    address public liquidator = address(0x30);
    address public borrower = address(0x10);
    address public usdc = address(0x100);
    address public ousg = address(0x200);

    function setUp() public {
        riskModule = new MockRiskModuleLiq();
        ledger = new MockBalanceLedgerLiq();
        assetRegistry = new MockAssetRegistryLiq();

        engine = LiquidationEngine(address(new TransparentUpgradeableProxy(
            address(new LiquidationEngine()), owner,
            abi.encodeCall(LiquidationEngine.initialize, (
                owner, address(ledger), address(riskModule), address(assetRegistry)
            ))
        )));

        vm.prank(owner);
        engine.setAuthorizedCaller(authorized, true);

        // Setup: borrower has OUSG collateral, is undercollateralized
        assetRegistry.setBehavior(ousg, 800); // 8% bonus (Tier 2)
        riskModule.setFresh(ousg, true);
        riskModule.setAssetPrice(ousg, 100e18); // $100 per OUSG token

        // CRIT-01 FIX: Liquidator must have debt asset balance to pay
        ledger.setAvailable(liquidator, usdc, 100_000e18);
    }

    // ============ Successful Liquidation ============

    function test_liquidate_success() public {
        // Borrower: HF = 0.9 (below 1.0), debt = 10,000 USDC
        riskModule.setHF(borrower, 0.9e18);
        riskModule.setDebt(borrower, 10_000e18);

        // Collateral: 100 OUSG at $100 each = $10,000
        ledger.setPosition(borrower, ousg, 100e18, 10_000e18);

        // Liquidator covers 50% = 5,000 USDC of debt
        vm.prank(liquidator);
        engine.liquidate(borrower, usdc, 5_000e18, ousg);

        // Collateral should be reduced (5000 + 8% bonus = 5400 USD worth)
        // 5400 / 10000 * 100 = 54 OUSG seized
        IBalanceLedger.CollateralPosition memory pos = ledger.getCollateralByAsset(borrower, ousg);
        assertEq(pos.amount, 46e18); // 100 - 54 = 46
    }

    // ============ Revert Cases ============

    function test_liquidate_reverts_healthy_position() public {
        riskModule.setHF(borrower, 1.5e18); // HF = 1.5 (healthy)
        riskModule.setDebt(borrower, 10_000e18);
        ledger.setPosition(borrower, ousg, 100e18, 15_000e18);

        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(ILiquidationEngine.PositionHealthy.selector, 1.5e18));
        engine.liquidate(borrower, usdc, 5_000e18, ousg);
    }

    function test_liquidate_reverts_exceeds_50_percent() public {
        riskModule.setHF(borrower, 0.9e18);
        riskModule.setDebt(borrower, 10_000e18);
        ledger.setPosition(borrower, ousg, 100e18, 10_000e18);

        // Try to cover 60% of debt = 6,000 (max is 5,000)
        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(ILiquidationEngine.ExceedsMaxDebtCoverage.selector, 6_000e18, 5_000e18));
        engine.liquidate(borrower, usdc, 6_000e18, ousg);
    }

    function test_liquidate_reverts_stale_price() public {
        riskModule.setHF(borrower, 0.9e18);
        riskModule.setDebt(borrower, 10_000e18);
        ledger.setPosition(borrower, ousg, 100e18, 10_000e18);
        riskModule.setFresh(ousg, false); // stale!

        vm.prank(liquidator);
        vm.expectRevert(ILiquidationEngine.PriceFeedStale.selector);
        engine.liquidate(borrower, usdc, 5_000e18, ousg);
    }

    // ============ Grace Period Tests ============

    function test_liquidate_reverts_during_grace_period() public {
        riskModule.setHF(borrower, 0.9e18);
        riskModule.setDebt(borrower, 10_000e18);
        ledger.setPosition(borrower, ousg, 100e18, 10_000e18);

        // Set grace period (6 hours)
        bytes32 positionId = keccak256(abi.encode(borrower, usdc, ousg));
        vm.prank(authorized);
        engine.setGracePeriod(positionId, 6, 0, 1600); // 6 hours, HF_TOO_LOW

        // Liquidation should revert during grace period
        vm.prank(liquidator);
        vm.expectRevert(); // GracePeriodNotExpired
        engine.liquidate(borrower, usdc, 5_000e18, ousg);
    }

    function test_liquidate_succeeds_after_grace_period() public {
        riskModule.setHF(borrower, 0.9e18);
        riskModule.setDebt(borrower, 10_000e18);
        ledger.setPosition(borrower, ousg, 100e18, 10_000e18);

        bytes32 positionId = keccak256(abi.encode(borrower, usdc, ousg));
        vm.prank(authorized);
        engine.setGracePeriod(positionId, 6, 0, 1600);

        // Warp past grace period
        vm.warp(block.timestamp + 7 hours);

        vm.prank(liquidator);
        engine.liquidate(borrower, usdc, 5_000e18, ousg);
        // Should succeed — grace period expired
    }

    function test_setGracePeriod_max_hours() public {
        bytes32 positionId = keccak256("test-pos");

        vm.prank(authorized);
        engine.setGracePeriod(positionId, 24, 0, 1600); // max allowed

        // Exceeds max
        vm.prank(authorized);
        vm.expectRevert(abi.encodeWithSelector(ILiquidationEngine.ExceedsMaxGracePeriod.selector, 25, 24));
        engine.setGracePeriod(positionId, 25, 0, 1600);
    }

    function test_isInGracePeriod() public {
        bytes32 positionId = keccak256("test-pos");

        assertFalse(engine.isInGracePeriod(positionId));

        vm.prank(authorized);
        engine.setGracePeriod(positionId, 6, 0, 1600);

        assertTrue(engine.isInGracePeriod(positionId));

        vm.warp(block.timestamp + 7 hours);
        assertFalse(engine.isInGracePeriod(positionId));
    }

    function test_flagForLiquidation() public {
        bytes32 positionId = keccak256("test-pos");

        vm.prank(authorized);
        engine.setGracePeriod(positionId, 1, 0, 1600);

        vm.warp(block.timestamp + 2 hours);

        vm.prank(authorized);
        engine.flagForLiquidation(positionId);

        assertTrue(engine.isLiquidatable(positionId));
    }

    // ============ Bonus Tiers ============

    function test_liquidation_bonus_tier2_8percent() public {
        // OUSG with 8% bonus
        riskModule.setHF(borrower, 0.9e18);
        riskModule.setDebt(borrower, 10_000e18);
        ledger.setPosition(borrower, ousg, 100e18, 10_000e18);

        vm.prank(liquidator);
        engine.liquidate(borrower, usdc, 5_000e18, ousg);

        // Collateral seized: 5000 * 1.08 / (10000/100) = 54 tokens
        IBalanceLedger.CollateralPosition memory pos = ledger.getCollateralByAsset(borrower, ousg);
        assertEq(pos.amount, 46e18);
    }
}
