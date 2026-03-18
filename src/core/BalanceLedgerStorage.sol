// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IBalanceLedger} from "../interfaces/IBalanceLedger.sol";

/// @title BalanceLedgerStorage
/// @notice Storage layout for BalanceLedger upgradeable contract
/// @dev All state variables for BalanceLedger. Maintains __gap for future upgrades.
///      NEVER reorder or remove variables — only append before __gap and reduce gap size.
abstract contract BalanceLedgerStorage {
    // ============ State Variables ============

    /// @notice Per-user per-asset balance with 4 sub-states
    /// @dev user => asset => UserBalance
    mapping(address => mapping(address => IBalanceLedger.UserBalance)) internal _balances;

    /// @notice Per-user collateral positions array
    /// @dev user => CollateralPosition[]
    mapping(address => IBalanceLedger.CollateralPosition[]) internal _collateral;

    /// @notice Per-user per-asset collateral toggle (Aave V3 pattern)
    /// @dev user => asset => bool
    mapping(address => mapping(address => bool)) internal _isUsedAsCollateral;

    /// @notice Contracts authorized to write to BalanceLedger (Security Invariant #9)
    /// @dev Only CentuariEndpoint, WithdrawalRegistry, YieldRouter, LiquidationEngine
    mapping(address => bool) internal _authorizedWriters;

    /// @notice Risk module address for HF safety checks
    address internal _riskModule;

    /// @notice Asset behavior registry for collateral eligibility checks
    address internal _assetBehaviorRegistry;

    /// @notice Paused state
    bool internal _paused;

    // ============ Gap ============

    /// @dev Reserved storage for future upgrades
    uint256[40] private __gap;
}
