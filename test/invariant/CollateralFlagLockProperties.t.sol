// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {BalanceLedger} from "../../src/core/balance-ledger/BalanceLedger.sol";
import {CollateralManager} from "../../src/core/collateral/CollateralManager.sol";
import {ICollateralManager} from "../../src/interfaces/ICollateralManager.sol";
import {MockRiskModule} from "../mocks/MockRiskModule.sol";

/// @title CollateralFlagLockPropertiesTest
/// @notice Fuzz property harness for the 24h flag-lock timing (CM-2), the
///         idempotent-mark guarantee that a re-flag never refreshes `_flaggedAt`
///         (BL-5 / CT-5), and the governance cap on the lock duration (CM-4).
contract CollateralFlagLockPropertiesTest is Test {
    BalanceLedger internal ledger;
    CollateralManager internal manager;
    MockRiskModule internal risk;

    address internal owner = address(0xA11CE);
    address internal operator = address(0x0B5E4A);
    address internal user = address(0x1111);
    address internal asset = address(0xA55E71);

    uint64 internal constant LOCK = 24 hours;
    uint256 internal constant START = 1_700_000_000;

    function setUp() public {
        BalanceLedger impl = new BalanceLedger();
        bytes memory ledgerInit = abi.encodeCall(BalanceLedger.initialize, (owner, true));
        ledger = BalanceLedger(address(new TransparentUpgradeableProxy(address(impl), address(this), ledgerInit)));

        // Permissive risk module: isolates the flag-lock timing from the HF gate.
        risk = new MockRiskModule();

        CollateralManager mgrImpl = new CollateralManager();
        bytes memory mgrInit =
            abi.encodeCall(CollateralManager.initialize, (owner, operator, address(ledger), address(risk)));
        manager = CollateralManager(address(new TransparentUpgradeableProxy(address(mgrImpl), address(this), mgrInit)));

        vm.prank(owner);
        ledger.forceAddWriter(address(manager));

        vm.warp(START);
    }

    /// @notice CM-2: unflag is blocked until `flaggedAt + flagLock`, and allowed
    ///         at or after it. Fuzz the elapsed time across the boundary.
    function testFuzz_CM2_flagLockBoundary(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, 60 days);

        vm.prank(operator);
        manager.flagFor(user, asset);
        uint64 flaggedAt = ledger.flaggedAt(user, asset);
        uint64 unlocksAt = flaggedAt + LOCK;

        vm.warp(uint256(flaggedAt) + elapsed);

        vm.prank(operator);
        if (block.timestamp < unlocksAt) {
            vm.expectRevert(abi.encodeWithSelector(ICollateralManager.FlagLockActive.selector, unlocksAt));
            manager.unflagFor(user, asset);
            assertTrue(ledger.usedAsCollateral(user, asset), "flag must persist while locked");
        } else {
            manager.unflagFor(user, asset);
            assertFalse(ledger.usedAsCollateral(user, asset), "unflag must succeed once lock elapsed");
        }
    }

    /// @notice BL-5 / CT-5: re-flagging an already-flagged pair at a later time is
    ///         idempotent — `_flaggedAt` stays pinned to the FIRST mark, so the
    ///         lock window cannot be extended by repeated marks.
    function testFuzz_BL5_remarkDoesNotRefreshFlaggedAt(uint256 gap1, uint256 gap2) public {
        gap1 = bound(gap1, 1, LOCK - 1); // still inside the lock window
        gap2 = bound(gap2, 1, 10 days);

        vm.prank(operator);
        manager.flagFor(user, asset);
        uint64 firstFlaggedAt = ledger.flaggedAt(user, asset);

        // Re-mark at a strictly later timestamp.
        vm.warp(START + gap1);
        vm.prank(operator);
        manager.flagFor(user, asset);
        assertEq(ledger.flaggedAt(user, asset), firstFlaggedAt, "re-mark must not refresh flaggedAt");

        // A second re-mark, also later.
        vm.warp(START + gap1 + gap2);
        vm.prank(operator);
        manager.flagFor(user, asset);
        assertEq(ledger.flaggedAt(user, asset), firstFlaggedAt, "second re-mark must not refresh flaggedAt");

        // The unlock instant is still measured from the FIRST mark: exactly at
        // firstFlaggedAt + LOCK the unflag is allowed.
        vm.warp(uint256(firstFlaggedAt) + LOCK);
        vm.prank(operator);
        manager.unflagFor(user, asset);
        assertFalse(ledger.usedAsCollateral(user, asset), "unflag at firstMark+LOCK must succeed despite re-marks");
    }

    /// @notice CM-3: even after the lock elapses, a denying RiskModule blocks the
    ///         unflag (fail-closed HF gate) with `WouldMakeUnhealthy`.
    function testFuzz_CM3_unflagBlockedByHfAfterLock(uint256 elapsed) public {
        elapsed = bound(elapsed, LOCK, 60 days);

        vm.prank(operator);
        manager.flagFor(user, asset);
        risk.setCanUnflag(false);

        vm.warp(START + elapsed);
        vm.prank(operator);
        vm.expectRevert(ICollateralManager.WouldMakeUnhealthy.selector);
        manager.unflagFor(user, asset);
        assertTrue(ledger.usedAsCollateral(user, asset), "flag must persist when HF gate denies unflag");
    }

    /// @notice CM-4: governance can never set the flag-lock above MAX_FLAG_LOCK
    ///         (30 days), so the unflag path can't be bricked.
    function testFuzz_CM4_flagLockCapEnforced(uint64 newLock) public {
        if (newLock <= manager.MAX_FLAG_LOCK()) {
            vm.prank(owner);
            manager.setFlagLock(newLock);
            assertEq(manager.flagLock(), newLock, "valid lock should be accepted");
        } else {
            vm.prank(owner);
            vm.expectRevert(ICollateralManager.FlagLockTooLong.selector);
            manager.setFlagLock(newLock);
        }
    }
}
