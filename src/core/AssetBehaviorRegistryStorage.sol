// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAssetBehaviorRegistry} from "../interfaces/IAssetBehaviorRegistry.sol";

/// @title AssetBehaviorRegistryStorage
/// @notice Storage layout for AssetBehaviorRegistry upgradeable contract
/// @dev NEVER reorder or remove variables — only append before __gap and reduce gap size.
abstract contract AssetBehaviorRegistryStorage {
    // ============ State Variables ============

    /// @notice Asset behavior configuration per token
    /// @dev asset address => AssetBehavior
    mapping(address => IAssetBehaviorRegistry.AssetBehavior) internal _behaviors;

    /// @notice Per-asset pause state (conservative action, no timelock required)
    mapping(address => bool) internal _assetPaused;

    /// @notice Pending LTV changes awaiting observation period
    mapping(address => IAssetBehaviorRegistry.LTVChange) internal _pendingLTVChanges;

    /// @notice Per-asset liquidator whitelist (for RWA collateral requiring KYC)
    mapping(address => mapping(address => bool)) internal _liquidatorWhitelist;

    /// @notice Per-asset liquidator list (for enumeration)
    mapping(address => address[]) internal _liquidatorList;

    /// @notice Timestamp when assets were added (for timelock enforcement)
    mapping(address => uint256) internal _assetAddedAt;

    /// @notice Timestamp of last update per asset (for timelock enforcement)
    mapping(address => uint256) internal _lastUpdateAt;

    /// @notice Market schedule registry address
    address internal _marketScheduleRegistry;

    /// @notice Timelock duration in seconds (48 hours = 172800)
    uint256 internal constant TIMELOCK_DURATION = 48 hours;

    /// @notice Observation period for LTV changes (30 days)
    uint256 internal constant LTV_OBSERVATION_PERIOD = 30 days;

    /// @notice Maximum liquidation bonus (2000 BPS = 20%)
    uint256 internal constant MAX_LIQUIDATION_BONUS_BPS = 2000;

    /// @notice Paused state
    bool internal _paused;

    /// @notice H-03 FIX: Pending asset proposals awaiting timelock
    mapping(address => IAssetBehaviorRegistry.AssetBehavior) internal _pendingAssets;

    /// @notice H-03 FIX: Timelock end timestamps for pending asset proposals
    mapping(address => uint256) internal _pendingAssetTimestamp;

    /// @notice Admin timelock duration
    uint256 internal constant ADMIN_TIMELOCK = 48 hours;

    /// @notice Pending admin address changes keyed by bytes32 identifier (48h timelock)
    mapping(bytes32 => address) internal _pendingAdminAddress;

    /// @notice Timelock end timestamps for pending admin address changes
    mapping(bytes32 => uint256) internal _pendingAdminTimelockEnd;

    // ============ Gap ============

    uint256[36] private __gap;
}
