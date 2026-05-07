// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ICollateralManager
/// @notice Interface for the CollateralManager policy wrapper around
///         BalanceLedger's collateral flag.
/// @dev CollateralManager is the ONLY Phase 1 entry point for mid-life
///      (non-settlement, non-repay) collateral flag writes. It enforces:
///        1. Operator role gating — only the protocol settlement key can call.
///        2. A 24-hour flag-lock on unflag — prevents gas-spam loops on the
///           protocol settlement key's nonce budget.
///        3. The `IRiskModule.canUnflag` policy gate — fail-closed in Phase 1,
///           HF-aware in Phase 2 once the real RiskModule lands.
///
///      BalanceLedger itself stays policy-free: it is a dumb accounting
///      substrate. All HF / timelock / role checks live here (for app-user
///      and admin writes) or in `WithdrawalRegistry` (for withdraw-time HF).
interface ICollateralManager {
    // ============ Events ============

    /// @notice Emitted when the operator address is updated
    /// @param previousOperator The prior operator
    /// @param newOperator The new operator
    event OperatorUpdated(address indexed previousOperator, address indexed newOperator);

    /// @notice Emitted when the RiskModule pointer is swapped
    /// @dev Phase 2 upgrade fires this once when the real RiskModule replaces
    ///      the Phase 1 stub. Consumers (indexer-v2, audit monitors) should
    ///      alert on this to track the policy migration.
    /// @param previousRiskModule The prior RiskModule address
    /// @param newRiskModule The new RiskModule address
    event RiskModuleUpdated(address indexed previousRiskModule, address indexed newRiskModule);

    /// @notice Emitted when the flag-lock duration is updated
    /// @param previousLock The prior lock duration in seconds
    /// @param newLock The new lock duration in seconds
    event FlagLockUpdated(uint64 previousLock, uint64 newLock);

    // ============ Errors ============

    /// @notice Thrown when a zero address is provided where a real address is required
    error ZeroAddress();

    /// @notice Thrown when a non-operator caller attempts an operator-only action
    error NotOperator();

    /// @notice Thrown when `unflagFor` is called for an asset that is not currently flagged
    error NotFlagged();

    /// @notice Thrown when `unflagFor` is called before the 24-hour flag-lock has elapsed
    /// @param unlocksAt The unix timestamp at which the lock expires
    error FlagLockActive(uint64 unlocksAt);

    /// @notice Thrown when the RiskModule rejects the unflag as unsafe
    error WouldMakeUnhealthy();

    /// @notice Thrown when `setFlagLock` is called with a value above the ceiling
    error FlagLockTooLong();

    // ============ Operator actions ============

    /// @notice Flag a (user, asset) as collateral on behalf of the user
    /// @dev Rarely used in Phase 1 — the common case is auto-flagging inside
    ///      `Settlement.settle()` on borrow-match settlement. This entry point
    ///      exists for admin edge cases and Phase 6 integrators that prefer
    ///      composing with CollateralManager over direct BalanceLedger writes.
    ///      No HF check is performed because flagging never worsens HF.
    /// @param user The user whose collateral to flag
    /// @param asset The asset to flag
    function flagFor(address user, address asset) external;

    /// @notice Unflag a (user, asset) as collateral on behalf of the user
    /// @dev Enforces, in order: flag must exist, 24-hour lock must have
    ///      elapsed, and `riskModule.canUnflag` must return true. Reverts with
    ///      the specific error on each failure so the backend can map it to a
    ///      distinct HTTP response code.
    /// @param user The user whose collateral to unflag
    /// @param asset The asset to unflag
    function unflagFor(address user, address asset) external;

    // ============ Direct-caller actions ============

    /// @notice Flag `msg.sender`'s asset as collateral
    /// @dev Direct-caller counterpart to `flagFor`: implicit `user = msg.sender`,
    ///      no operator gate. Used by the frontend's emergency "Flag now"
    ///      affordance (user-signed, user-paid) and by Phase 6 integrators that
    ///      compose with CollateralManager rather than the operator key. Routes
    ///      through the same internal `_flag` helper as `flagFor` so flagging
    ///      semantics are uniform across the two paths. No HF check (flagging
    ///      strictly improves HF).
    /// @param asset The asset to flag for the caller
    function flag(address asset) external;

    /// @notice Unflag `msg.sender`'s asset as collateral
    /// @dev Direct-caller counterpart to `unflagFor`: implicit `user = msg.sender`,
    ///      no operator gate. Routes through the same internal `_unflag` helper
    ///      so the 24h flag-lock and `IRiskModule.canUnflag` gate cannot be
    ///      bypassed by picking this entry point over `unflagFor`. Trustlessness
    ///      invariant: a user can always exit their own collateral position even
    ///      if the backend is down.
    /// @param asset The asset to unflag for the caller
    function unflag(address asset) external;

    // ============ Governance actions ============

    /// @notice Update the operator that may call `flagFor` / `unflagFor`
    /// @param newOperator The new operator address
    function setOperator(address newOperator) external;

    /// @notice Swap the RiskModule implementation
    /// @dev This is the single Phase 2 upgrade point. Governance calls this
    ///      with the address of a new, oracle-backed `RiskModule` and the
    ///      "unflag while in debt iff HF stays healthy" capability lights up
    ///      instantly with zero changes in any caller contract.
    /// @param newRiskModule The new RiskModule address
    function setRiskModule(address newRiskModule) external;

    /// @notice Update the flag-lock duration
    /// @dev Lets governance tune the 24-hour default without a redeploy if
    ///      operational data suggests a different window. Cannot be set above
    ///      a sane ceiling to avoid bricking the unflag path.
    /// @param newFlagLock The new flag-lock duration in seconds
    function setFlagLock(uint64 newFlagLock) external;

    // ============ Views ============

    /// @notice The BalanceLedger this manager writes to
    function balanceLedger() external view returns (address);

    /// @notice The current RiskModule policy pointer
    function riskModule() external view returns (address);

    /// @notice The current operator address
    function operator() external view returns (address);

    /// @notice The current flag-lock duration in seconds
    function flagLock() external view returns (uint64);
}
