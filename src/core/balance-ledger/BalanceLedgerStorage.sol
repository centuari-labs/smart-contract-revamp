// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title BalanceLedgerStorage
/// @notice Storage layout for the upgradeable BalanceLedger contract
/// @dev BalanceLedger is the on-chain source of truth for per-user, per-asset
///      balances across three sub-states: available, inOrders, inYieldRouter.
///
///      Phase 1 only writes `available` (via credit/debit). The `inOrders` and
///      `inYieldRouter` fields are reserved for Phase 6 (CentuariRouter) and
///      Phase 5B (YieldRouter) and MUST stay in storage from day one so the
///      layout remains forward-compatible.
///
///      There is NO on-chain `collateral` sub-state and NO on-chain
///      `usedAsCollateral` flag in Phase 1. Collateral is HF-gated virtual
///      (Aave/Compound pattern): the `usedAsCollateral` flag lives off-chain
///      in indexer-v2's Postgres because (a) it has zero on-chain consumers in
///      Phase 1 and (b) putting it on-chain would let users spam the protocol's
///      settlement gas budget for free. See
///      `docs/phase-1-cross-chain-balance-ledger.md` §Module 1 for the full
///      rationale and the deferred Phase 2 / 6 migration paths.
///
///      IMPORTANT: Only append new storage variables to the end of this contract.
///      Never reorder, remove, or change types of existing variables.
abstract contract BalanceLedgerStorage {
    // ============ Constants ============

    /// @notice Minimum delay between proposing and executing a new authorized writer
    /// @dev 48 hours per the Phase 1 plan (C2). Cannot be bypassed in production.
    uint256 internal constant WRITER_TIMELOCK = 48 hours;

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

    // ============ Storage Gap ============

    /// @notice Storage gap for future upgrades
    /// @dev Provides 45 slots for future storage variables.
    ///      When adding new variables, reduce this gap accordingly.
    ///      Current usage: 2 bool slots + 3 mappings = 5 slots.
    uint256[45] private __gap;
}
