// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {BalanceLedger} from "../../src/core/balance-ledger/BalanceLedger.sol";
import {CollateralManager} from "../../src/core/collateral/CollateralManager.sol";
import {RiskModuleStub} from "../../src/core/risk/RiskModuleStub.sol";
import {ICollateralManager} from "../../src/interfaces/ICollateralManager.sol";
import {IRiskModule} from "../../src/interfaces/IRiskModule.sol";

/// @title PermissiveRiskModule
/// @notice Test-only RiskModule that always returns true. Used to decouple the
///         CollateralManager "unflag-after-lock" happy-path test from the
///         deliberately fail-closed Phase 1 stub.
contract PermissiveRiskModule is IRiskModule {
    function canUnflag(address, address) external pure returns (bool) {
        return true;
    }

    function canWithdraw(address, address, uint256) external pure returns (bool) {
        return true;
    }
}

contract CollateralManagerTest is Test {
    BalanceLedger internal ledger;
    CollateralManager internal manager;
    RiskModuleStub internal stub;
    PermissiveRiskModule internal permissive;

    address internal owner = address(0xA11CE);
    address internal operatorAddr = address(0x0B5E4A);
    address internal outsider = address(0xDEAD);
    address internal user = address(0x1111);
    address internal asset = address(0xA55E71);
    address internal asset2 = address(0xA55E72);

    function setUp() public {
        // Deploy BalanceLedger behind a proxy.
        BalanceLedger impl = new BalanceLedger();
        bytes memory ledgerInit = abi.encodeCall(BalanceLedger.initialize, (owner, true));
        TransparentUpgradeableProxy ledgerProxy =
            new TransparentUpgradeableProxy(address(impl), address(this), ledgerInit);
        ledger = BalanceLedger(address(ledgerProxy));

        // Deploy the stub and a permissive alt for the happy-path test.
        stub = new RiskModuleStub(address(ledger));
        permissive = new PermissiveRiskModule();

        // Deploy CollateralManager behind a proxy, with the fail-closed stub.
        CollateralManager mgrImpl = new CollateralManager();
        bytes memory mgrInit =
            abi.encodeCall(CollateralManager.initialize, (owner, operatorAddr, address(ledger), address(stub)));
        TransparentUpgradeableProxy mgrProxy = new TransparentUpgradeableProxy(address(mgrImpl), address(this), mgrInit);
        manager = CollateralManager(address(mgrProxy));

        // Authorize the manager as a BalanceLedger writer (testnet fast path).
        vm.prank(owner);
        ledger.forceAddWriter(address(manager));
    }

    // ============ Initialization ============

    function test_Initialize_SetsState() public view {
        assertEq(manager.owner(), owner);
        assertEq(manager.operator(), operatorAddr);
        assertEq(manager.balanceLedger(), address(ledger));
        assertEq(manager.riskModule(), address(stub));
        assertEq(manager.flagLock(), 24 hours);
    }

    function test_Initialize_RevertZeroAddresses() public {
        CollateralManager mgrImpl = new CollateralManager();

        bytes memory badOwner =
            abi.encodeCall(CollateralManager.initialize, (address(0), operatorAddr, address(ledger), address(stub)));
        vm.expectRevert(ICollateralManager.ZeroAddress.selector);
        new TransparentUpgradeableProxy(address(mgrImpl), address(this), badOwner);

        bytes memory badOperator =
            abi.encodeCall(CollateralManager.initialize, (owner, address(0), address(ledger), address(stub)));
        vm.expectRevert(ICollateralManager.ZeroAddress.selector);
        new TransparentUpgradeableProxy(address(mgrImpl), address(this), badOperator);

        bytes memory badLedger =
            abi.encodeCall(CollateralManager.initialize, (owner, operatorAddr, address(0), address(stub)));
        vm.expectRevert(ICollateralManager.ZeroAddress.selector);
        new TransparentUpgradeableProxy(address(mgrImpl), address(this), badLedger);

        bytes memory badRisk =
            abi.encodeCall(CollateralManager.initialize, (owner, operatorAddr, address(ledger), address(0)));
        vm.expectRevert(ICollateralManager.ZeroAddress.selector);
        new TransparentUpgradeableProxy(address(mgrImpl), address(this), badRisk);
    }

    // ============ flagFor ============

    function test_FlagFor_MarksLedger() public {
        vm.warp(1_700_000_000);
        vm.prank(operatorAddr);
        manager.flagFor(user, asset);

        assertTrue(ledger.usedAsCollateral(user, asset));
        assertEq(ledger.flaggedAt(user, asset), uint64(block.timestamp));
    }

    function test_FlagFor_RevertNonOperator() public {
        vm.prank(outsider);
        vm.expectRevert(ICollateralManager.NotOperator.selector);
        manager.flagFor(user, asset);
    }

    // ============ unflagFor ============

    function test_UnflagFor_RevertWhenNotFlagged() public {
        vm.prank(operatorAddr);
        vm.expectRevert(ICollateralManager.NotFlagged.selector);
        manager.unflagFor(user, asset);
    }

    function test_UnflagFor_RevertFlagLockActiveBefore24h() public {
        vm.warp(1_700_000_000);
        vm.prank(operatorAddr);
        manager.flagFor(user, asset);

        uint64 flaggedAt = ledger.flaggedAt(user, asset);
        uint64 unlocksAt = flaggedAt + 24 hours;

        // 1 second before the lock expires.
        vm.warp(unlocksAt - 1);
        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(ICollateralManager.FlagLockActive.selector, unlocksAt));
        manager.unflagFor(user, asset);
    }

    function test_UnflagFor_RevertWouldMakeUnhealthyWhenStubBlocks() public {
        vm.warp(1_700_000_000);
        vm.prank(operatorAddr);
        manager.flagFor(user, asset);

        // Warp past the lock. Stub still returns canUnflag = false.
        vm.warp(block.timestamp + 24 hours);
        vm.prank(operatorAddr);
        vm.expectRevert(ICollateralManager.WouldMakeUnhealthy.selector);
        manager.unflagFor(user, asset);
    }

    function test_UnflagFor_SucceedsAfter24hWhenRiskModulePermits() public {
        // Swap in the permissive RiskModule to isolate the flag-lock / write
        // path from the Phase 1 stub's fail-closed policy.
        vm.prank(owner);
        manager.setRiskModule(address(permissive));

        vm.warp(1_700_000_000);
        vm.prank(operatorAddr);
        manager.flagFor(user, asset);

        // Exactly at the 24h boundary.
        vm.warp(block.timestamp + 24 hours);
        vm.prank(operatorAddr);
        manager.unflagFor(user, asset);

        assertFalse(ledger.usedAsCollateral(user, asset));
        assertEq(ledger.flaggedAt(user, asset), 0);
    }

    function test_UnflagFor_RevertNonOperator() public {
        vm.prank(operatorAddr);
        manager.flagFor(user, asset);

        vm.prank(outsider);
        vm.expectRevert(ICollateralManager.NotOperator.selector);
        manager.unflagFor(user, asset);
    }

    /// @notice The load-bearing test: repeated marks must NOT extend the lock.
    /// @dev Mark, warp 23h, mark again (no-op), warp another 1h 30m — total
    ///      24.5h from the original flag. With a permissive RiskModule the
    ///      unflag must succeed because the lock is pinned to the FIRST mark.
    function test_RepeatedMark_DoesNotExtendLock() public {
        vm.prank(owner);
        manager.setRiskModule(address(permissive));

        vm.warp(1_700_000_000);
        vm.prank(operatorAddr);
        manager.flagFor(user, asset);
        uint64 firstStamp = ledger.flaggedAt(user, asset);

        // 23h later — lock is still active, re-flag (idempotent no-op).
        vm.warp(block.timestamp + 23 hours);
        vm.prank(operatorAddr);
        manager.flagFor(user, asset);
        assertEq(ledger.flaggedAt(user, asset), firstStamp, "stamp was refreshed");

        // 1h 30m later — total 24.5h from the first flag. Unflag must succeed.
        vm.warp(block.timestamp + 1 hours + 30 minutes);
        vm.prank(operatorAddr);
        manager.unflagFor(user, asset);

        assertFalse(ledger.usedAsCollateral(user, asset));
    }

    // ============ Governance ============

    function test_SetRiskModule_SwapsImplementation() public {
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit ICollateralManager.RiskModuleUpdated(address(stub), address(permissive));
        manager.setRiskModule(address(permissive));

        assertEq(manager.riskModule(), address(permissive));
    }

    function test_SetRiskModule_RevertNonOwner() public {
        vm.prank(outsider);
        vm.expectRevert();
        manager.setRiskModule(address(permissive));
    }

    function test_SetRiskModule_RevertZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(ICollateralManager.ZeroAddress.selector);
        manager.setRiskModule(address(0));
    }

    function test_SetOperator_Updates() public {
        address newOperator = address(0xFEED);
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit ICollateralManager.OperatorUpdated(operatorAddr, newOperator);
        manager.setOperator(newOperator);

        assertEq(manager.operator(), newOperator);

        // Old operator loses access.
        vm.prank(operatorAddr);
        vm.expectRevert(ICollateralManager.NotOperator.selector);
        manager.flagFor(user, asset);
    }

    function test_SetFlagLock_Updates() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit ICollateralManager.FlagLockUpdated(24 hours, 12 hours);
        manager.setFlagLock(12 hours);

        assertEq(manager.flagLock(), 12 hours);
    }

    function test_SetFlagLock_RevertAboveCeiling() public {
        // Read the ceiling BEFORE pranking — `vm.prank` only applies to the
        // next call, and `manager.MAX_FLAG_LOCK()` would consume it otherwise.
        uint64 ceiling = manager.MAX_FLAG_LOCK();
        vm.prank(owner);
        vm.expectRevert(ICollateralManager.FlagLockTooLong.selector);
        manager.setFlagLock(ceiling + 1);
    }

    function test_SetFlagLock_AcceptsZero() public {
        // Zero disables the lock — useful for tests or emergency policy. The
        // RiskModule gate still applies.
        vm.prank(owner);
        manager.setFlagLock(0);
        assertEq(manager.flagLock(), 0);

        vm.prank(owner);
        manager.setRiskModule(address(permissive));

        vm.prank(operatorAddr);
        manager.flagFor(user, asset2);

        // Unflag works in the same block because the lock is 0.
        vm.prank(operatorAddr);
        manager.unflagFor(user, asset2);
        assertFalse(ledger.usedAsCollateral(user, asset2));
    }

    // ============ Direct caller — flag(asset) ============

    function test_Flag_DirectCaller_MarksLedger() public {
        vm.warp(1_700_000_000);
        // No vm.prank to operator — `user` calls directly for themselves.
        vm.prank(user);
        manager.flag(asset);

        assertTrue(ledger.usedAsCollateral(user, asset));
        assertEq(ledger.flaggedAt(user, asset), uint64(block.timestamp));
    }

    /// @notice Proves the absence of `onlyOperator` on the direct path.
    /// @dev `outsider` is not the operator; the call must still succeed for
    ///      `outsider` flagging their own asset (msg.sender == outsider).
    function test_Flag_DirectCaller_NoOperatorGate() public {
        vm.warp(1_700_000_000);
        vm.prank(outsider);
        manager.flag(asset);

        assertTrue(ledger.usedAsCollateral(outsider, asset));
        assertEq(ledger.flaggedAt(outsider, asset), uint64(block.timestamp));
        // Sanity: flagging self does not flag a different user.
        assertFalse(ledger.usedAsCollateral(user, asset));
    }

    // ============ Direct caller — unflag(asset) ============

    function test_Unflag_DirectCaller_RevertNotFlagged() public {
        vm.prank(user);
        vm.expectRevert(ICollateralManager.NotFlagged.selector);
        manager.unflag(asset);
    }

    function test_Unflag_DirectCaller_RevertFlagLockActiveBefore24h() public {
        vm.warp(1_700_000_000);
        vm.prank(user);
        manager.flag(asset);

        uint64 flaggedAt = ledger.flaggedAt(user, asset);
        uint64 unlocksAt = flaggedAt + 24 hours;

        // 1 second before the lock expires.
        vm.warp(unlocksAt - 1);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ICollateralManager.FlagLockActive.selector, unlocksAt));
        manager.unflag(asset);
    }

    function test_Unflag_DirectCaller_RevertWouldMakeUnhealthyWhenStubBlocks() public {
        vm.warp(1_700_000_000);
        vm.prank(user);
        manager.flag(asset);

        // Warp past the lock. Stub still returns canUnflag = false.
        vm.warp(block.timestamp + 24 hours);
        vm.prank(user);
        vm.expectRevert(ICollateralManager.WouldMakeUnhealthy.selector);
        manager.unflag(asset);
    }

    function test_Unflag_DirectCaller_SucceedsAfter24hWhenRiskModulePermits() public {
        // Swap in the permissive RiskModule to isolate the flag-lock / write
        // path from the Phase 1 stub's fail-closed policy.
        vm.prank(owner);
        manager.setRiskModule(address(permissive));

        vm.warp(1_700_000_000);
        vm.prank(user);
        manager.flag(asset);

        // Exactly at the 24h boundary.
        vm.warp(block.timestamp + 24 hours);
        vm.prank(user);
        manager.unflag(asset);

        assertFalse(ledger.usedAsCollateral(user, asset));
        assertEq(ledger.flaggedAt(user, asset), 0);
    }

    /// @notice The single-policy-seam invariant: a user cannot flag via the
    ///         operator path and unflag via the direct path to bypass the
    ///         24h lock or RiskModule gate (or vice versa). Both entry-point
    ///         families share `_unflag`, so the gate fires uniformly.
    function test_Unflag_DirectCaller_SamePolicyAsOperatorPath() public {
        // Flag via the operator path.
        vm.warp(1_700_000_000);
        vm.prank(operatorAddr);
        manager.flagFor(user, asset);

        // Try to unflag via the direct path BEFORE the lock expires — must
        // hit FlagLockActive identically to the operator path.
        uint64 unlocksAt = ledger.flaggedAt(user, asset) + 24 hours;
        vm.warp(unlocksAt - 1);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ICollateralManager.FlagLockActive.selector, unlocksAt));
        manager.unflag(asset);

        // Past the lock the stub still rejects via WouldMakeUnhealthy — same
        // policy seam regardless of which entry point is used.
        vm.warp(unlocksAt);
        vm.prank(user);
        vm.expectRevert(ICollateralManager.WouldMakeUnhealthy.selector);
        manager.unflag(asset);
    }

    // ============ Refactor regressions ============

    /// @notice Regression: the operator path still works after the refactor.
    /// @dev `flagFor` now delegates to `_flag`. The 17 existing tests prove
    ///      the operator path is intact at the function level; this test
    ///      exercises a happy-path round trip through the operator path
    ///      after the refactor specifically.
    function test_FlagFor_OperatorPath_StillWorks() public {
        vm.warp(1_700_000_000);
        vm.prank(operatorAddr);
        manager.flagFor(user, asset);
        assertTrue(ledger.usedAsCollateral(user, asset));

        vm.prank(owner);
        manager.setRiskModule(address(permissive));

        vm.warp(block.timestamp + 24 hours);
        vm.prank(operatorAddr);
        manager.unflagFor(user, asset);
        assertFalse(ledger.usedAsCollateral(user, asset));
    }

    /// @notice Regression: the operator path's flag-lock check still fires
    ///         after extracting `_unflag`.
    function test_UnflagFor_OperatorPath_StillReverts_FlagLockActive() public {
        vm.warp(1_700_000_000);
        vm.prank(operatorAddr);
        manager.flagFor(user, asset);

        uint64 unlocksAt = ledger.flaggedAt(user, asset) + 24 hours;
        vm.warp(unlocksAt - 1);
        vm.prank(operatorAddr);
        vm.expectRevert(abi.encodeWithSelector(ICollateralManager.FlagLockActive.selector, unlocksAt));
        manager.unflagFor(user, asset);
    }
}
