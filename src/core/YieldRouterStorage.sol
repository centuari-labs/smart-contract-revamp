// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IYieldRouter} from "../interfaces/IYieldRouter.sol";

/// @title YieldRouterStorage
/// @notice Storage layout for YieldRouter upgradeable contract
abstract contract YieldRouterStorage {
    /// @notice BalanceLedger contract
    address internal _balanceLedger;

    /// @notice AssetBehaviorRegistry contract
    address internal _assetBehaviorRegistry;

    /// @notice Per-user per-asset router enabled flag
    mapping(address => mapping(address => bool)) internal _routerEnabled;

    /// @notice Per-adapter pause expiry (72h auto-expiry)
    mapping(address => uint256) internal _adapterPauseExpiry;

    /// @notice InsuranceReserve balance per asset
    mapping(address => uint256) internal _insuranceReserve;

    /// @notice Total deployed capital per asset (across all adapters)
    mapping(address => uint256) internal _totalDeployed;

    /// @notice Per-adapter per-asset deployed amounts
    mapping(address => mapping(address => uint256)) internal _adapterDeployed;

    /// @notice Multisig address (for adapter pause)
    address internal _multisig;

    /// @notice Authorized callers
    mapping(address => bool) internal _authorizedCallers;

    /// @notice Per-user per-asset per-adapter shares tracking
    /// user => asset => adapter => shares
    mapping(address => mapping(address => mapping(address => uint256))) internal _userAdapterShares;

    /// @notice Registered adapters (for iteration during recall)
    address[] internal _registeredAdapters;

    /// @notice Max per-protocol allocation in BPS
    uint256 internal constant _MAX_PER_PROTOCOL_BPS = 6000;

    /// @notice Min InsuranceReserve ratio in BPS
    uint256 internal constant _MIN_RESERVE_RATIO_BPS = 1000;

    /// @notice Min cash buffer in BPS (15%)
    uint256 internal constant _VAULT_RAW_MINIMUM_BPS = 1500;

    /// @notice BPS denominator
    uint256 internal constant BPS_DENOMINATOR = 10000;

    /// @notice Adapter pause duration (72 hours)
    uint256 internal constant ADAPTER_PAUSE_DURATION = 72 hours;
    uint256 internal constant ADMIN_TIMELOCK = 48 hours;

    /// @notice Pending admin address changes keyed by bytes32 identifier (48h timelock)
    mapping(bytes32 => address) internal _pendingAdminAddress;

    /// @notice Timelock end timestamps for pending admin address changes
    mapping(bytes32 => uint256) internal _pendingAdminTimelockEnd;

    /// @notice Pending authorized-caller bool keyed by caller address (48h timelock)
    mapping(address => bool) internal _pendingAdminBool;

    /// @notice C2 FIX: Track all assets that have been deployed to any adapter
    /// @dev Used by verifyReserveRatio() to iterate and check all deployed assets
    address[] internal _deployedAssets;

    /// @notice C2 FIX: Quick lookup to avoid duplicate entries in _deployedAssets
    mapping(address => bool) internal _isDeployedAsset;

    /// @notice M-01 FIX: Pending adapter registration with 48h timelock
    /// @dev Moved from YieldRouter.sol implementation to prevent storage corruption on upgrade.
    address internal _pendingAdapter;
    uint256 internal _pendingAdapterTimelockEnd;

    // ============ Gap ============

    uint256[31] private __gap;
}
