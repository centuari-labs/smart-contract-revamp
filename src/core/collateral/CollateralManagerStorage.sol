// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title CollateralManagerStorage
/// @notice Storage layout for the upgradeable CollateralManager contract
/// @dev IMPORTANT: Only append new storage variables to the end.
///      Never reorder, remove, or change types of existing variables.
abstract contract CollateralManagerStorage {
    // ============ Storage Variables ============

    /// @notice The BalanceLedger this manager writes into
    /// @dev Set once at initialization. If BalanceLedger is ever redeployed,
    ///      a fresh CollateralManager should be deployed alongside it rather
    ///      than swapping this pointer — the two contracts share a trust
    ///      boundary (writer allowlist) that is easier to reason about when
    ///      they are deployed as a unit.
    address internal _balanceLedger;

    /// @notice The current RiskModule policy pointer
    /// @dev Swapped by governance via `setRiskModule` to upgrade Phase 1
    ///      stub → Phase 2 oracle-backed implementation without touching any
    ///      caller contract.
    address internal _riskModule;

    /// @notice The operator allowed to call flagFor/unflagFor
    /// @dev In Phase 1 this is the protocol settlement key used by backend-v2
    ///      for app-user mid-life collateral writes. Phase 6 integrators get
    ///      their own CollateralManager deployment or direct BalanceLedger
    ///      writer access — they do NOT share this operator slot.
    address internal _operator;

    /// @notice The flag-lock duration in seconds
    /// @dev Defaults to 24 hours at initialization. Enforced by `unflagFor`
    ///      against `BalanceLedger.flaggedAt(user, asset)`. Tunable by owner
    ///      within a sane ceiling to avoid bricking the unflag path.
    uint64 internal _flagLock;

    // ============ Storage Gap ============

    /// @notice Storage gap for future upgrades
    /// @dev Provides 46 slots for future storage variables. The four above
    ///      pack into two slots (three addresses + one uint64, where the
    ///      uint64 shares a slot with no neighbor because Solidity only
    ///      packs sequential variables — so the count is three full slots
    ///      + one slot holding only the uint64 = four slots consumed from
    ///      the original 50-slot budget).
    uint256[46] private __gap;
}
