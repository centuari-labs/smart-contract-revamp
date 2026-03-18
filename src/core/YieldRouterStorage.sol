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

    // ============ Gap ============

    uint256[38] private __gap;
}
