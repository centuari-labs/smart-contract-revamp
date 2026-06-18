// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IBalanceLedger
/// @notice Interface for the BalanceLedger contract — the on-chain source of
///         truth for per-user, per-asset balances across three sub-states plus
///         the on-chain `usedAsCollateral` flag.
/// @dev Phase 1 writers: Centuari.sol, CollateralManager.sol, and later
///      HubDepositor, WithdrawalRegistry, HubIntentSettler, etc. via the 48h
///      governance path. Phase 1 only mutates `available`; `inOrders` and
///      `inYieldRouter` are forward-compat slots and always read as zero.
///      The `usedAsCollateral` flag lives on-chain so that `WithdrawalRegistry`
///      (permissionless) can enforce the HF gate uniformly for every caller.
interface IBalanceLedger {
    // ============ Events ============

    /// @notice Emitted when an authorized writer credits a user's available balance
    /// @param writer The authorized writer that performed the credit
    /// @param user The user whose balance increased
    /// @param asset The asset address
    /// @param amount The amount credited
    /// @param newAvailable The user's available balance after the credit
    event Credited(
        address indexed writer, address indexed user, address indexed asset, uint256 amount, uint256 newAvailable
    );

    /// @notice Emitted when an authorized writer debits a user's available balance
    /// @param writer The authorized writer that performed the debit
    /// @param user The user whose balance decreased
    /// @param asset The asset address
    /// @param amount The amount debited
    /// @param newAvailable The user's available balance after the debit
    event Debited(
        address indexed writer, address indexed user, address indexed asset, uint256 amount, uint256 newAvailable
    );

    /// @notice Emitted when a new authorized writer is proposed (starts 48h timer)
    /// @param writer The address proposed
    /// @param proposedAt Block timestamp of the proposal
    event WriterProposed(address indexed writer, uint256 proposedAt);

    /// @notice Emitted when a previously-proposed writer is granted write access
    /// @param writer The address granted write access
    event WriterAdded(address indexed writer);

    /// @notice Emitted when an authorized writer is removed (instant, no timelock)
    /// @param writer The address removed from the authorized writers set
    event WriterRemoved(address indexed writer);

    /// @notice Emitted when a proposed writer is cancelled before execution
    /// @param writer The address whose proposal was cancelled
    event WriterProposalCancelled(address indexed writer);

    /// @notice Emitted when the contract is paused
    /// @param account The account that paused the contract
    event Paused(address account);

    /// @notice Emitted when the contract is unpaused
    /// @param account The account that unpaused the contract
    event Unpaused(address account);

    /// @notice Emitted when a (user, asset) collateral flag transitions state
    /// @dev Fires on every `false → true` transition (with a fresh `flaggedAt`
    ///      stamp) and every `true → false` transition (with `flaggedAt = 0`).
    ///      Idempotent no-op calls (marking an already-flagged pair, unmarking
    ///      an already-unflagged pair) do NOT emit. Indexer-v2 mirrors the
    ///      `user_balance.used_as_collateral` / `flagged_at` columns from this
    ///      event.
    /// @param writer The authorized writer that performed the flag transition
    /// @param user The user whose collateral flag changed
    /// @param asset The asset whose flag changed
    /// @param used The new flag state (true = flagged, false = unflagged)
    /// @param flaggedAt The new `_flaggedAt` stamp (block.timestamp on mark, 0 on unmark)
    event CollateralFlagSet(
        address indexed writer, address indexed user, address indexed asset, bool used, uint64 flaggedAt
    );

    // ============ Errors ============

    /// @notice Thrown when caller is not authorized (not an authorized writer or not owner)
    error Unauthorized();

    /// @notice Thrown when a zero address is provided where a real address is required
    error ZeroAddress();

    /// @notice Thrown when an amount is zero
    error ZeroAmount();

    /// @notice Thrown when an action is attempted while the contract is paused
    error ContractPaused();

    /// @notice Thrown when a debit or move exceeds the caller's source balance
    error InsufficientBalance();

    /// @notice Thrown when attempting to propose a writer that is already authorized
    error WriterAlreadyAuthorized();

    /// @notice Thrown when attempting to propose a writer that already has a pending proposal
    error WriterAlreadyProposed();

    /// @notice Thrown when attempting to execute a writer proposal that does not exist
    error WriterNotProposed();

    /// @notice Thrown when attempting to execute a writer proposal before the timelock expires
    error WriterTimelockNotElapsed();

    /// @notice Thrown when attempting to remove a writer that is not currently authorized
    error WriterNotAuthorized();

    /// @notice Thrown when attempting to use the testnet force-add-writer path on a
    ///         BalanceLedger that was initialized with force-registration disabled
    error ForceRegistrationDisabled();

    /// @notice Thrown when a user would exceed MAX_FLAGGED_ASSETS flagged collateral assets (SC-5)
    error TooManyFlaggedAssets();

    // ============ Balance Mutators (authorized writers only) ============

    /// @notice Credit a user's available balance
    /// @dev Must be called by an authorized writer. No token transfer happens
    ///      here — this is pure accounting. The caller is responsible for
    ///      pulling the real tokens into custody before calling credit, or
    ///      trusting a separate token-custody contract that already did so.
    /// @param user The user whose balance to increase
    /// @param asset The asset address
    /// @param amount The amount to credit (must be > 0)
    function credit(address user, address asset, uint256 amount) external;

    /// @notice Debit a user's available balance
    /// @dev Reverts with `InsufficientBalance` if `amount` exceeds the user's
    ///      current available balance.
    /// @param user The user whose balance to decrease
    /// @param asset The asset address
    /// @param amount The amount to debit (must be > 0)
    function debit(address user, address asset, uint256 amount) external;

    // ============ Collateral Flag Mutators (authorized writers only) ============

    /// @notice Mark a (user, asset) as collateral
    /// @dev Idempotent. If the pair is already flagged this is a no-op and does
    ///      NOT refresh `_flaggedAt` — so repeated borrows that reuse the same
    ///      collateral never extend the 24-hour flag-lock enforced by
    ///      `CollateralManager.unflagFor`. The lock is always pinned to the
    ///      first mark. Emits `CollateralFlagSet` only on a real state change.
    /// @param user The user whose collateral flag to set
    /// @param asset The asset being marked as collateral
    function markCollateral(address user, address asset) external;

    /// @notice Unmark a (user, asset) as collateral
    /// @dev Idempotent. If the pair is not currently flagged this is a no-op.
    ///      Does NOT enforce the 24-hour flag-lock — that policy lives in the
    ///      caller (`CollateralManager.unflagFor`). `Centuari.repay` calls this
    ///      directly on the repay-to-zero path, bypassing the lock, because a
    ///      fully repaid user is trivially HF-safe and should exit cleanly.
    /// @param user The user whose collateral flag to clear
    /// @param asset The asset being unmarked
    function unmarkCollateral(address user, address asset) external;

    // ============ Writer Management (owner only) ============

    /// @notice Propose a new authorized writer; starts the 48h timelock
    /// @dev Reverts if `writer` is already authorized or already proposed.
    /// @param writer The address to propose
    function proposeAuthorizedWriter(address writer) external;

    /// @notice Execute a previously-proposed writer after the 48h timelock
    /// @dev Reverts if no proposal exists or the timelock has not elapsed.
    /// @param writer The address to grant write access
    function executeAuthorizedWriter(address writer) external;

    /// @notice Cancel a pending writer proposal before it is executed
    /// @param writer The address whose proposal should be dropped
    function cancelWriterProposal(address writer) external;

    /// @notice Force-add an authorized writer without waiting for the timelock
    /// @dev Only callable if `forceWriterRegistrationEnabled` was set to true at
    ///      initialization. Intended for testnet / local deploy scripts only.
    /// @param writer The address to grant write access immediately
    function forceAddWriter(address writer) external;

    /// @notice Remove an authorized writer (instant, no timelock)
    /// @dev Used for incident response. The 48h delay is only for additions.
    /// @param writer The address to remove from the authorized writers set
    function removeAuthorizedWriter(address writer) external;

    // ============ Pause Control (owner only) ============

    /// @notice Pause all balance mutations
    function pause() external;

    /// @notice Unpause the contract
    function unpause() external;

    // ============ Views ============

    /// @notice Read a user's available balance for an asset
    function available(address user, address asset) external view returns (uint256);

    /// @notice Read a user's in-orders balance (always zero in Phase 1)
    function inOrders(address user, address asset) external view returns (uint256);

    /// @notice Read a user's in-yield-router balance (always zero in Phase 1)
    function inYieldRouter(address user, address asset) external view returns (uint256);

    /// @notice Read the sum of all three sub-states for a user / asset
    function total(address user, address asset) external view returns (uint256);

    /// @notice Check whether an address is currently an authorized writer
    function isAuthorizedWriter(address writer) external view returns (bool);

    /// @notice Read the timestamp at which a writer was proposed (0 = none)
    function writerProposedAt(address writer) external view returns (uint256);

    /// @notice Whether the contract is currently paused
    function paused() external view returns (bool);

    /// @notice Whether force-writer-registration was enabled at init time
    function forceWriterRegistrationEnabled() external view returns (bool);

    /// @notice Read whether a (user, asset) is currently flagged as collateral
    /// @param user The user to query
    /// @param asset The asset to query
    /// @return True if the asset is flagged as collateral for the user
    function usedAsCollateral(address user, address asset) external view returns (bool);

    /// @notice Enumerate every asset currently flagged as collateral for a user
    /// @dev Returns a snapshot copy of the `_flaggedAssets[user]` set. The order
    ///      is unspecified and may change across calls due to the underlying
    ///      `EnumerableSet` swap-and-pop removal. Intended for the repay-to-zero
    ///      auto-unflag loop in `Centuari.repay` and off-chain HF jobs.
    /// @param user The user to query
    /// @return Array of asset addresses currently flagged for the user
    function flaggedAssetsOf(address user) external view returns (address[] memory);

    /// @notice Read the timestamp at which a (user, asset) was most recently flagged
    /// @dev Zero when the pair is not currently flagged. Used by
    ///      `CollateralManager.unflagFor` to enforce the 24-hour flag-lock.
    /// @param user The user to query
    /// @param asset The asset to query
    /// @return Unix seconds of the latest `false → true` transition, or 0
    function flaggedAt(address user, address asset) external view returns (uint64);
}
