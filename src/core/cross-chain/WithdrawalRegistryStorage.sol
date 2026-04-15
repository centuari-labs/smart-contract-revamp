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

    /// @notice Physical-token liquidity available per (token, chainId) pair.
    /// @dev Used by M5 to capacity-gate SPOKE_NATIVE withdrawals: tokens that
    ///      never bridge back to the hub (e.g. XSGD on Base) can only be
    ///      withdrawn to chains where their liquidity has been previously
    ///      registered via `confirmDeposit`. Incremented on spoke-native
    ///      deposit confirmation, decremented atomically with the
    ///      `BalanceLedger.debit` inside `requestWithdrawal`.
    ///
    ///      For BRIDGED assets this mapping is expected to stay at 0 — the
    ///      capacity gate is bypassed when the target chain routing flag
    ///      indicates the token is bridgeable (matrix lookup lives off-chain
    ///      in matching-engine / backend; the on-chain check only runs if
    ///      the operator flags the request as SPOKE_NATIVE).
    mapping(address => mapping(uint256 => uint256)) internal _chainLiquidity;

    // ============ Storage Gap ============

    /// @notice Storage gap for future upgrades
    /// @dev 8 slots consumed, leaving 42 from the 50-slot budget.
    uint256[42] private __gap;
}
