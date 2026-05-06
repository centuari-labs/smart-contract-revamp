// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {BalanceLedger} from "../../src/core/balance-ledger/BalanceLedger.sol";
import {IBalanceLedger} from "../../src/interfaces/IBalanceLedger.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @title BalanceLedgerTest
/// @notice Foundry test suite for BalanceLedger Module 1 (Phase 1A).
/// @dev Covers:
///      - initialization + access control
///      - credit/debit happy paths and reverts
///      - writer proposal → 48h timelock → execution
///      - forceAddWriter (testnet path)
///      - pause / unpause gating
///      - fuzz: ledger invariant that `available` equals total credits minus
///              total debits across a random sequence of operations
contract BalanceLedgerTest is Test {
    BalanceLedger internal ledger;

    address internal proxyAdminOwner;
    address internal owner;
    address internal writer;
    address internal outsider;
    address internal user1;
    address internal user2;
    address internal asset1;
    address internal asset2;

    // ============ Setup ============

    function setUp() public {
        proxyAdminOwner = address(this);
        owner = address(0xA11CE);
        writer = address(0xBEEF);
        outsider = address(0xDEAD);
        user1 = address(0x1111);
        user2 = address(0x2222);
        asset1 = address(0xA55E71);
        asset2 = address(0xA55E72);

        ledger = _deployLedger(owner, true);

        // Register a writer immediately via the testnet force path.
        vm.prank(owner);
        ledger.forceAddWriter(writer);
    }

    // ============ Helpers ============

    function _deployLedger(address owner_, bool forceWriterRegistrationEnabled_) internal returns (BalanceLedger) {
        BalanceLedger impl = new BalanceLedger();
        bytes memory initData = abi.encodeCall(BalanceLedger.initialize, (owner_, forceWriterRegistrationEnabled_));
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(impl), proxyAdminOwner, initData);
        return BalanceLedger(address(proxy));
    }

    // ============ Initialization ============

    function test_Initialize() public view {
        assertEq(ledger.owner(), owner);
        assertTrue(ledger.forceWriterRegistrationEnabled());
        assertFalse(ledger.paused());
        assertTrue(ledger.isAuthorizedWriter(writer));
    }

    function test_Initialize_RevertZeroOwner() public {
        BalanceLedger impl = new BalanceLedger();
        bytes memory initData = abi.encodeCall(BalanceLedger.initialize, (address(0), false));
        vm.expectRevert(IBalanceLedger.ZeroAddress.selector);
        new TransparentUpgradeableProxy(address(impl), proxyAdminOwner, initData);
    }

    function test_Initialize_RevertDoubleInit() public {
        vm.expectRevert();
        ledger.initialize(owner, true);
    }

    function test_Initialize_ProductionDeploymentDisablesForcePath() public {
        BalanceLedger prod = _deployLedger(owner, false);
        assertFalse(prod.forceWriterRegistrationEnabled());

        vm.prank(owner);
        vm.expectRevert(IBalanceLedger.ForceRegistrationDisabled.selector);
        prod.forceAddWriter(writer);
    }

    // ============ Credit ============

    function test_Credit_Success() public {
        vm.prank(writer);
        vm.expectEmit(true, true, true, true);
        emit IBalanceLedger.Credited(writer, user1, asset1, 100, 100);
        ledger.credit(user1, asset1, 100);

        assertEq(ledger.available(user1, asset1), 100);
        assertEq(ledger.total(user1, asset1), 100);
    }

    function test_Credit_Accumulates() public {
        vm.startPrank(writer);
        ledger.credit(user1, asset1, 100);
        ledger.credit(user1, asset1, 250);
        vm.stopPrank();

        assertEq(ledger.available(user1, asset1), 350);
    }

    function test_Credit_RevertUnauthorized() public {
        vm.prank(outsider);
        vm.expectRevert(IBalanceLedger.Unauthorized.selector);
        ledger.credit(user1, asset1, 100);
    }

    function test_Credit_RevertZeroUser() public {
        vm.prank(writer);
        vm.expectRevert(IBalanceLedger.ZeroAddress.selector);
        ledger.credit(address(0), asset1, 100);
    }

    function test_Credit_RevertZeroAsset() public {
        vm.prank(writer);
        vm.expectRevert(IBalanceLedger.ZeroAddress.selector);
        ledger.credit(user1, address(0), 100);
    }

    function test_Credit_RevertZeroAmount() public {
        vm.prank(writer);
        vm.expectRevert(IBalanceLedger.ZeroAmount.selector);
        ledger.credit(user1, asset1, 0);
    }

    function test_Credit_RevertWhenPaused() public {
        vm.prank(owner);
        ledger.pause();

        vm.prank(writer);
        vm.expectRevert(IBalanceLedger.ContractPaused.selector);
        ledger.credit(user1, asset1, 100);
    }

    // ============ Debit ============

    function test_Debit_Success() public {
        vm.startPrank(writer);
        ledger.credit(user1, asset1, 500);
        vm.expectEmit(true, true, true, true);
        emit IBalanceLedger.Debited(writer, user1, asset1, 200, 300);
        ledger.debit(user1, asset1, 200);
        vm.stopPrank();

        assertEq(ledger.available(user1, asset1), 300);
    }

    function test_Debit_RevertInsufficientBalance() public {
        vm.startPrank(writer);
        ledger.credit(user1, asset1, 100);
        vm.expectRevert(IBalanceLedger.InsufficientBalance.selector);
        ledger.debit(user1, asset1, 101);
        vm.stopPrank();
    }

    function test_Debit_RevertUnauthorized() public {
        vm.prank(writer);
        ledger.credit(user1, asset1, 100);

        vm.prank(outsider);
        vm.expectRevert(IBalanceLedger.Unauthorized.selector);
        ledger.debit(user1, asset1, 50);
    }

    function test_Debit_RevertZeroAmount() public {
        vm.prank(writer);
        vm.expectRevert(IBalanceLedger.ZeroAmount.selector);
        ledger.debit(user1, asset1, 0);
    }

    // ============ Forward-compat sub-states always zero in Phase 1 ============

    function test_ForwardCompat_InOrdersAlwaysZero() public {
        vm.prank(writer);
        ledger.credit(user1, asset1, 1_000);
        assertEq(ledger.inOrders(user1, asset1), 0);
    }

    function test_ForwardCompat_InYieldRouterAlwaysZero() public {
        vm.prank(writer);
        ledger.credit(user1, asset1, 1_000);
        assertEq(ledger.inYieldRouter(user1, asset1), 0);
    }

    // ============ Writer management — 48h timelock path ============

    function test_ProposeAuthorizedWriter_StartsTimer() public {
        address newWriter = address(0xC0FFEE);

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit IBalanceLedger.WriterProposed(newWriter, block.timestamp);
        ledger.proposeAuthorizedWriter(newWriter);

        assertEq(ledger.writerProposedAt(newWriter), block.timestamp);
        assertFalse(ledger.isAuthorizedWriter(newWriter));
    }

    function test_ProposeAuthorizedWriter_RevertNonOwner() public {
        vm.prank(outsider);
        vm.expectRevert();
        ledger.proposeAuthorizedWriter(address(0xC0FFEE));
    }

    function test_ProposeAuthorizedWriter_RevertAlreadyAuthorized() public {
        vm.prank(owner);
        vm.expectRevert(IBalanceLedger.WriterAlreadyAuthorized.selector);
        ledger.proposeAuthorizedWriter(writer);
    }

    function test_ProposeAuthorizedWriter_RevertDuplicateProposal() public {
        address newWriter = address(0xC0FFEE);
        vm.startPrank(owner);
        ledger.proposeAuthorizedWriter(newWriter);
        vm.expectRevert(IBalanceLedger.WriterAlreadyProposed.selector);
        ledger.proposeAuthorizedWriter(newWriter);
        vm.stopPrank();
    }

    function test_ExecuteAuthorizedWriter_RequiresFullTimelock() public {
        address newWriter = address(0xC0FFEE);
        vm.prank(owner);
        ledger.proposeAuthorizedWriter(newWriter);

        // Just before the timelock expires.
        vm.warp(block.timestamp + 48 hours - 1);
        vm.prank(owner);
        vm.expectRevert(IBalanceLedger.WriterTimelockNotElapsed.selector);
        ledger.executeAuthorizedWriter(newWriter);

        // Exactly at the timelock boundary.
        vm.warp(block.timestamp + 1);
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit IBalanceLedger.WriterAdded(newWriter);
        ledger.executeAuthorizedWriter(newWriter);

        assertTrue(ledger.isAuthorizedWriter(newWriter));
        assertEq(ledger.writerProposedAt(newWriter), 0);
    }

    function test_ExecuteAuthorizedWriter_RevertNoProposal() public {
        vm.prank(owner);
        vm.expectRevert(IBalanceLedger.WriterNotProposed.selector);
        ledger.executeAuthorizedWriter(address(0xC0FFEE));
    }

    function test_CancelWriterProposal_Drops() public {
        address newWriter = address(0xC0FFEE);
        vm.startPrank(owner);
        ledger.proposeAuthorizedWriter(newWriter);
        ledger.cancelWriterProposal(newWriter);
        vm.stopPrank();

        assertEq(ledger.writerProposedAt(newWriter), 0);
        assertFalse(ledger.isAuthorizedWriter(newWriter));
    }

    function test_RemoveAuthorizedWriter_Instant() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit IBalanceLedger.WriterRemoved(writer);
        ledger.removeAuthorizedWriter(writer);

        assertFalse(ledger.isAuthorizedWriter(writer));

        vm.prank(writer);
        vm.expectRevert(IBalanceLedger.Unauthorized.selector);
        ledger.credit(user1, asset1, 100);
    }

    function test_RemoveAuthorizedWriter_RevertNotAuthorized() public {
        vm.prank(owner);
        vm.expectRevert(IBalanceLedger.WriterNotAuthorized.selector);
        ledger.removeAuthorizedWriter(address(0xC0FFEE));
    }

    function test_ForceAddWriter_ClearsPendingProposal() public {
        address newWriter = address(0xC0FFEE);
        vm.startPrank(owner);
        ledger.proposeAuthorizedWriter(newWriter);
        ledger.forceAddWriter(newWriter);
        vm.stopPrank();

        assertTrue(ledger.isAuthorizedWriter(newWriter));
        assertEq(ledger.writerProposedAt(newWriter), 0);
    }

    // ============ Pause ============

    function test_Pause_BlocksAllMutators() public {
        vm.prank(owner);
        ledger.pause();
        assertTrue(ledger.paused());

        vm.startPrank(writer);
        vm.expectRevert(IBalanceLedger.ContractPaused.selector);
        ledger.credit(user1, asset1, 1);
        vm.expectRevert(IBalanceLedger.ContractPaused.selector);
        ledger.debit(user1, asset1, 1);
        vm.stopPrank();
    }

    function test_Unpause_RestoresMutators() public {
        vm.startPrank(owner);
        ledger.pause();
        ledger.unpause();
        vm.stopPrank();

        vm.prank(writer);
        ledger.credit(user1, asset1, 42);
        assertEq(ledger.available(user1, asset1), 42);
    }

    // ============ Fuzz — ledger invariant ============

    /// @notice Fuzz: after any sequence of credit/debit operations, `available`
    ///         equals `total credits - total debits` and the ledger never
    ///         underflows.
    /// @dev `inOrders` and `inYieldRouter` are always zero in Phase 1, so the
    ///      sum of sub-states should equal `available`.
    function testFuzz_Invariant_CreditMinusDebitEqualsSum(uint96[16] memory credits, uint96[16] memory debits) public {
        uint256 totalCredited;
        uint256 totalDebited;

        for (uint256 i = 0; i < credits.length; i++) {
            if (credits[i] == 0) continue;
            vm.prank(writer);
            ledger.credit(user1, asset1, credits[i]);
            totalCredited += credits[i];
        }

        for (uint256 i = 0; i < debits.length; i++) {
            uint256 d = debits[i];
            uint256 currentAvailable = ledger.available(user1, asset1);
            if (d == 0 || d > currentAvailable) continue;
            vm.prank(writer);
            ledger.debit(user1, asset1, d);
            totalDebited += d;
        }

        uint256 av = ledger.available(user1, asset1);

        // Core conservation: available == credits - debits.
        assertEq(av, totalCredited - totalDebited);

        // Forward-compat fields are untouched.
        assertEq(ledger.inOrders(user1, asset1), 0);
        assertEq(ledger.inYieldRouter(user1, asset1), 0);

        // total() matches the raw sum (3 sub-states, two of them zero).
        assertEq(ledger.total(user1, asset1), av);
    }

    /// @notice Fuzz: balances for distinct (user, asset) pairs are fully isolated.
    function testFuzz_BalancesAreIsolated(uint96 a, uint96 b, uint96 c, uint96 d) public {
        vm.assume(a > 0 && b > 0 && c > 0 && d > 0);

        vm.startPrank(writer);
        ledger.credit(user1, asset1, a);
        ledger.credit(user1, asset2, b);
        ledger.credit(user2, asset1, c);
        ledger.credit(user2, asset2, d);
        vm.stopPrank();

        assertEq(ledger.available(user1, asset1), a);
        assertEq(ledger.available(user1, asset2), b);
        assertEq(ledger.available(user2, asset1), c);
        assertEq(ledger.available(user2, asset2), d);
    }

    // ============ Collateral flag — mark / unmark / views ============

    function test_MarkCollateral_SetsFlagAndStampsTime() public {
        vm.warp(1_700_000_000);

        vm.prank(writer);
        vm.expectEmit(true, true, true, true);
        emit IBalanceLedger.CollateralFlagSet(writer, user1, asset1, true, uint64(block.timestamp));
        ledger.markCollateral(user1, asset1);

        assertTrue(ledger.usedAsCollateral(user1, asset1));
        assertEq(ledger.flaggedAt(user1, asset1), uint64(block.timestamp));

        address[] memory flagged = ledger.flaggedAssetsOf(user1);
        assertEq(flagged.length, 1);
        assertEq(flagged[0], asset1);
    }

    function test_MarkCollateral_IdempotentDoesNotRefreshTimestamp() public {
        vm.warp(1_700_000_000);

        vm.prank(writer);
        ledger.markCollateral(user1, asset1);
        uint64 firstStamp = ledger.flaggedAt(user1, asset1);

        // Advance time by 12 hours and re-mark — timestamp must NOT refresh.
        // This is the load-bearing semantic behind the 24h flag-lock: repeat
        // borrows that reuse the same collateral cannot extend the lockout.
        vm.warp(block.timestamp + 12 hours);

        // A real state-change emit would fire; capturing no emit would require
        // `vm.recordLogs`. Simpler: assert the timestamp stayed put.
        vm.prank(writer);
        ledger.markCollateral(user1, asset1);

        assertEq(ledger.flaggedAt(user1, asset1), firstStamp);
        assertTrue(ledger.usedAsCollateral(user1, asset1));
    }

    function test_UnmarkCollateral_ClearsFlag() public {
        vm.warp(1_700_000_000);
        vm.startPrank(writer);
        ledger.markCollateral(user1, asset1);

        vm.expectEmit(true, true, true, true);
        emit IBalanceLedger.CollateralFlagSet(writer, user1, asset1, false, 0);
        ledger.unmarkCollateral(user1, asset1);
        vm.stopPrank();

        assertFalse(ledger.usedAsCollateral(user1, asset1));
        assertEq(ledger.flaggedAt(user1, asset1), 0);
        assertEq(ledger.flaggedAssetsOf(user1).length, 0);
    }

    function test_UnmarkCollateral_IdempotentNoOp() public {
        // Unmarking a never-flagged pair is a no-op and must not revert.
        vm.prank(writer);
        ledger.unmarkCollateral(user1, asset1);
        assertFalse(ledger.usedAsCollateral(user1, asset1));
    }

    function test_FlaggedAssetsOf_ReturnsSet() public {
        vm.startPrank(writer);
        ledger.markCollateral(user1, asset1);
        ledger.markCollateral(user1, asset2);
        vm.stopPrank();

        address[] memory flagged = ledger.flaggedAssetsOf(user1);
        assertEq(flagged.length, 2);

        // Order is unspecified (EnumerableSet swap-and-pop); assert contents.
        bool saw1;
        bool saw2;
        for (uint256 i; i < flagged.length; ++i) {
            if (flagged[i] == asset1) saw1 = true;
            if (flagged[i] == asset2) saw2 = true;
        }
        assertTrue(saw1);
        assertTrue(saw2);

        // Remove asset1 and confirm the set shrinks.
        vm.prank(writer);
        ledger.unmarkCollateral(user1, asset1);

        address[] memory after_ = ledger.flaggedAssetsOf(user1);
        assertEq(after_.length, 1);
        assertEq(after_[0], asset2);
    }

    function test_MarkCollateral_RevertUnauthorized() public {
        vm.prank(outsider);
        vm.expectRevert(IBalanceLedger.Unauthorized.selector);
        ledger.markCollateral(user1, asset1);
    }

    function test_UnmarkCollateral_RevertUnauthorized() public {
        vm.prank(outsider);
        vm.expectRevert(IBalanceLedger.Unauthorized.selector);
        ledger.unmarkCollateral(user1, asset1);
    }

    function test_MarkCollateral_RevertWhenPaused() public {
        vm.prank(owner);
        ledger.pause();

        vm.prank(writer);
        vm.expectRevert(IBalanceLedger.ContractPaused.selector);
        ledger.markCollateral(user1, asset1);
    }

    function test_MarkCollateral_RevertZeroAddress() public {
        vm.startPrank(writer);
        vm.expectRevert(IBalanceLedger.ZeroAddress.selector);
        ledger.markCollateral(address(0), asset1);
        vm.expectRevert(IBalanceLedger.ZeroAddress.selector);
        ledger.markCollateral(user1, address(0));
        vm.stopPrank();
    }
}
