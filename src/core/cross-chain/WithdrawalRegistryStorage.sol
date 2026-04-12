// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IWithdrawalRegistry} from "../../interfaces/cross-chain/IWithdrawalRegistry.sol";

/// @title WithdrawalRegistryStorage
/// @notice Storage layout for the upgradeable WithdrawalRegistry contract
/// @dev IMPORTANT: Only append new storage variables to the end.
///      Never reorder, remove, or change types of existing variables.
abstract contract WithdrawalRegistryStorage {
    // ============ Storage Variables ============

    /// @notice The BalanceLedger this registry reads/writes
    address internal _balanceLedger;

    /// @notice The RiskModule consulted for HF checks on every withdrawal
    /// @dev Phase 2 swap point: governance updates this to the oracle-backed
    ///      RiskModule via `setRiskModule`.
    address internal _riskModule;

    /// @notice The HubDepositor for hub-native withdrawal payouts
    address internal _hubDepositor;

    /// @notice The operator address (backend-v2 settlement key)
    address internal _operator;

    /// @notice Whether the contract is paused
    bool internal _paused;

    /// @notice Monotonic counter for generating unique request IDs
    uint256 internal _requestCounter;

    /// @notice Withdrawal request records keyed by requestId
    mapping(bytes32 => IWithdrawalRegistry.WithdrawalRequest)
        internal _requests;

    // ============ Storage Gap ============

    /// @notice Storage gap for future upgrades
    /// @dev 7 slots consumed, leaving 43 from the 50-slot budget.
    uint256[43] private __gap;
}
