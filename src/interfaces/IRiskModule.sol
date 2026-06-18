// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IRiskModule
/// @notice Single interface seam for collateral-aware policy checks across the
///         Centuari protocol.
/// @dev The implementation is the oracle-backed `RiskModule`, which computes
///      real health factors from on-chain debt and price feeds. Callers
///      (`CollateralManager.unflagFor`, `WithdrawalRegistry.requestWithdrawal`)
///      depend only on this interface, and a single `setRiskModule(newAddr)`
///      governance call lets a future implementation be hot-swapped in without
///      touching any consumer contract.
///
///      IMPORTANT: Implementations MUST be view / pure and MUST NOT revert on
///      the expected decision paths. Callers treat a `false` return as a
///      policy rejection and surface a dedicated error; a revert from the
///      RiskModule would bubble up and obscure the real reason.
interface IRiskModule {
    /// @notice Whether a user may currently unflag a specific collateral asset
    /// @dev Called by `CollateralManager.unflagFor` after it has already
    ///      verified the 24-hour flag-lock has elapsed. Returns `true` iff
    ///      removing this collateral would leave the user's health factor ≥ 1.
    /// @param user The user considering the unflag
    /// @param asset The asset they want to unflag
    /// @return True if the unflag is permitted under current policy
    function canUnflag(address user, address asset) external view returns (bool);

    /// @notice Whether a user may currently withdraw a given amount of an asset
    /// @dev Called by `WithdrawalRegistry.requestWithdrawal` as its first
    ///      action, uniformly for every caller (app user, direct integrator,
    ///      Phase 6 `CentuariRouter`). Returns `true` iff the post-withdrawal
    ///      health factor stays ≥ 1 (fail-closed if any required price is
    ///      missing or stale).
    /// @param user The user initiating the withdrawal
    /// @param asset The asset being withdrawn
    /// @param amount The amount being withdrawn
    /// @return True if the withdrawal is permitted under current policy
    function canWithdraw(address user, address asset, uint256 amount) external view returns (bool);

    /// @notice The user's current health factor (1e18-scaled), with no pending action.
    /// @dev Returns `type(uint256).max` when the user has no active debt. Returns 0
    ///      when the position is underwater (collateral ≤ debt) OR any required price
    ///      is missing/stale (fail-closed). Otherwise the live HF. View / never reverts.
    /// @param user The account to value
    /// @return The 1e18-scaled health factor
    function healthFactor(address user) external view returns (uint256);

    /// @notice Whether the user's position may be liquidated right now (HF trigger).
    /// @dev True iff the user has debt, all inputs are priced, and HF < 1e18. The
    ///      trigger floor is exactly 1.0 with NO buffer — below the `1 + buffer`
    ///      borrow/withdraw gate, leaving a deliberate safety band. FAIL-CLOSED: a
    ///      missing/stale price returns false (never liquidate on uncertainty), the
    ///      inverse of `canWithdraw`. No debt returns false. View / never reverts.
    /// @param user The account to test
    /// @return True if the position is liquidatable under current policy
    function isLiquidatable(address user) external view returns (bool);
}
