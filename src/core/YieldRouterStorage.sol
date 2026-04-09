// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title YieldRouterStorage
/// @notice Storage layout for the thin YieldRouter proxy.
/// @dev Complex yield logic (per-user tracking, allocation, rebalancing) is OFF-CHAIN.
///      This storage only tracks protocol-level totals for on-chain verification.
///      NEVER reorder or remove variables — only append before __gap and reduce gap size.
abstract contract YieldRouterStorage {
    /// @notice BalanceLedger contract — tokens move between here and adapters
    address internal _balanceLedger;

    /// @notice Multisig address (for adapter pause + emergency recall)
    address internal _multisig;

    /// @notice Authorized callers (CentuariEndpoint, keeper)
    mapping(address => bool) internal _authorizedCallers;

    /// @notice Total deployed capital per asset (across all adapters)
    /// @dev Used for on-chain yield verification: actualYield = adapterValue - totalDeployed
    mapping(address => uint256) internal _totalDeployed;

    /// @notice Per-adapter per-asset deployed amounts
    mapping(address => mapping(address => uint256)) internal _adapterDeployed;

    /// @notice Registered adapters (for iteration)
    address[] internal _registeredAdapters;

    /// @notice Quick lookup for registered adapters
    mapping(address => bool) internal _isRegisteredAdapter;

    /// @notice Per-adapter pause expiry (72h auto-expiry)
    mapping(address => uint256) internal _adapterPauseExpiry;

    /// @notice Pending admin address changes (48h timelock)
    mapping(bytes32 => address) internal _pendingAdminAddress;
    mapping(bytes32 => uint256) internal _pendingAdminTimelockEnd;
    mapping(address => bool) internal _pendingAdminBool;

    /// @notice Pending adapter registration (48h timelock)
    address internal _pendingAdapter;
    uint256 internal _pendingAdapterTimelockEnd;

    // ============ Constants ============

    /// @notice Adapter pause duration (72 hours)
    uint256 internal constant ADAPTER_PAUSE_DURATION = 72 hours;

    /// @notice Admin timelock duration
    uint256 internal constant ADMIN_TIMELOCK = 48 hours;

    // ============ Gap ============

    /// @dev Reserved for future upgrades.
    uint256[40] private __gap;
}
