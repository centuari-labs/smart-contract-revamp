// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title BalanceLedgerStorage
/// @notice Storage layout for the upgradeable BalanceLedger contract
/// @dev BalanceLedger is the on-chain source of truth for per-user, per-asset
///      balances across three sub-states: available, inOrders, inYieldRouter,
///      plus an on-chain `usedAsCollateral` flag with per-(user, asset) flag
///      timestamps used by the 24-hour flag-lock enforced in CollateralManager.
///
///      Phase 1 only writes `available` (via credit/debit). The `inOrders` and
///      `inYieldRouter` fields are reserved for Phase 6 (CentuariRouter) and
///      Phase 5B (YieldRouter) and MUST stay in storage from day one so the
///      layout remains forward-compatible.
///
///      The `usedAsCollateral` flag lives ON-CHAIN so that a single HF gate in
///      `WithdrawalRegistry` (via `IRiskModule.canWithdraw`) can reject
///      permissionless withdrawals of flagged collateral uniformly for every
///      caller — app users routed through the backend AND direct on-chain
///      integrators (Phase 6 `CentuariRouter`). An off-chain flag could not
///      close that loophole because the permissionless `WithdrawalRegistry`
///      cannot read Postgres. See
///      `docs/phase-1-cross-chain-balance-ledger.md` §Module 1 / C1 for the
///      full rationale and the Phase 2 RiskModule swap path.
///
///      IMPORTANT: Only append new storage variables to the end of this contract.
///      Never reorder, remove, or change types of existing variables.
abstract contract BalanceLedgerStorage {
    using EnumerableSet for EnumerableSet.AddressSet;
    // ============ Constants ============

    /// @notice Minimum delay between proposing and executing a new authorized writer
    /// @dev 48 hours per the Phase 1 plan (C2). Cannot be bypassed in production.
    uint256 internal constant WRITER_TIMELOCK = 48 hours;

    /// @notice Max distinct flagged collateral assets a single user may hold (SC-5)
    /// @dev Bounds the RiskModule's on-chain HF loop, which prices every flagged
    ///      asset (one oracle call each). An unbounded set would let a user push
    ///      their own withdraw/unflag gas past the block limit. The mark that would
    ///      exceed this cap reverts with TooManyFlaggedAssets.
    uint256 internal constant MAX_FLAGGED_ASSETS = 32;

    // ============ Structs ============

    /// @notice Per-(user, asset) balance with three sub-states
    /// @dev `inOrders` and `inYieldRouter` are forward-compat fields; Phase 1 never
    ///      writes them, but they occupy storage so the layout is frozen for later
    ///      phases that add on-chain order locks and yield routing. There is no
    ///      on-chain `collateral` sub-state — collateral is HF-gated virtual and
    ///      the `usedAsCollateral` flag lives off-chain in indexer-v2 Postgres.
    /// @param available Freely usable balance (deposits, settled proceeds)
    /// @param inOrders Locked by on-chain router integrations (Phase 6). Zero in Phase 1.
    /// @param inYieldRouter Deposited into YieldRouter adapters (Phase 5B). Zero in Phase 1.
    struct Balance {
        uint256 available;
        uint256 inOrders;
        uint256 inYieldRouter;
    }

    /// @notice Pending addition of an authorized writer
    /// @dev Two-step add: propose -> wait WRITER_TIMELOCK -> execute.
    ///      The testnet deploy script may bypass the wait via `forceAddWriter`,
    ///      which is gated on `_forceWriterRegistrationEnabled` being true at
    ///      initialization time (testnet only).
    /// @param proposedAt Timestamp when the writer was proposed; 0 if no pending proposal
    struct WriterProposal {
        uint256 proposedAt;
    }

    // ============ Storage Variables ============

    /// @notice Whether the contract is paused
    /// @dev When paused, all balance-mutating functions revert.
    bool internal _paused;

    /// @notice Whether `forceAddWriter` (bypassing the 48h timelock) is enabled
    /// @dev Set once at initialize time. Intended for testnet / local devnet only.
    ///      Production deployments MUST pass `false` during initialization.
    bool internal _forceWriterRegistrationEnabled;

    /// @notice Per-user, per-asset balance snapshot across all three sub-states
    /// @dev user => asset => Balance
    mapping(address => mapping(address => Balance)) internal _balances;

    /// @notice Whether an address is authorized to call credit / debit
    /// @dev Phase 1 initial writer set: Centuari.sol proxy only.
    ///      HubDepositor, WithdrawalRegistry, HubIntentSettler, CentuariEndpoint,
    ///      YieldRouter, LiquidationEngine are added over time via the timelock.
    mapping(address => bool) internal _authorizedWriters;

    /// @notice Pending writer proposals awaiting the 48h timelock
    /// @dev writer address => WriterProposal
    mapping(address => WriterProposal) internal _writerProposals;

    /// @notice Whether a given (user, asset) is flagged as collateral
    /// @dev Written by authorized writers via `markCollateral` / `unmarkCollateral`.
    ///      Read on-chain by `IRiskModule` implementations to enforce HF gates
    ///      inside `CollateralManager.unflagFor` and `WithdrawalRegistry.requestWithdrawal`.
    mapping(address => mapping(address => bool)) internal _usedAsCollateral;

    /// @notice Per-user set of assets currently flagged as collateral
    /// @dev Enables the repay-to-zero auto-unflag loop in `Centuari.repay` (P1b)
    ///      and off-chain HF computations to enumerate a user's active collateral
    ///      without iterating over every known asset. Maintained in lockstep with
    ///      `_usedAsCollateral` by `markCollateral` / `unmarkCollateral`.
    mapping(address => EnumerableSet.AddressSet) internal _flaggedAssets;

    /// @notice Timestamp of the most recent `false → true` transition per (user, asset)
    /// @dev Used by `CollateralManager.unflagFor` to enforce the 24-hour flag-lock.
    ///      Idempotent `markCollateral` calls do NOT refresh this value — the lock
    ///      is pinned to the first mark, so repeated borrows reusing the same
    ///      collateral do not extend the lockup. Cleared on `unmarkCollateral`.
    ///      `uint64` holds unix seconds until year 2554 — safe.
    mapping(address => mapping(address => uint64)) internal _flaggedAt;

    /// @notice Guardian allowed to pause()/unpause() with no timelock delay.
    /// @dev Separate from owner() so the emergency stop stays fast while owner()
    ///      (a 24h TimelockController in production) governs every other setter.
    ///      Set to owner_ at initialize; rotated via setPauser (onlyOwner). (D1)
    address internal _pauser;

    // ============ Storage Gap ============

    /// @notice Storage gap for future upgrades
    /// @dev Provides 41 slots for future storage variables.
    ///      When adding new variables, reduce this gap accordingly.
    ///      Current usage: 2 bool slots + 3 balance/writer mappings
    ///      + 3 collateral mappings (_usedAsCollateral, _flaggedAssets, _flaggedAt)
    ///      + _pauser = 9 slots.
    uint256[41] private __gap;
}
