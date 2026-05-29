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
    mapping(bytes32 => IWithdrawalRegistry.WithdrawalRequest) internal _requests;

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

    /// @notice Marks (asset, chainId) pairs as spoke-native routes for
    ///         capacity gating in `requestWithdrawal`. Set by owner during
    ///         spoke deployment configuration.
    mapping(address => mapping(uint256 => bool)) internal _isSpokeNativeRoute;

    /// @notice The HubIntentSettler allowed to call `incrementChainLiquidity`.
    address internal _hubIntentSettler;

    /// @notice LZ V2 endpoint for dispatching payout messages to spoke chains.
    address internal _payoutEndpoint;

    /// @notice LZ eid → SpokePayout peer (bytes32) on each spoke chain.
    mapping(uint32 => bytes32) internal _payoutPeers;

    /// @notice EIP-155 chainId → LZ eid mapping for spoke chains.
    mapping(uint256 => uint32) internal _spokeEidByChainId;

    /// @notice Guardian allowed to pause()/unpause() with no timelock delay.
    /// @dev Separate from owner() so the emergency stop stays fast while owner()
    ///      (a 24h TimelockController in production) governs every other setter.
    ///      Set to owner_ at initialize; rotated via setPauser (onlyOwner). (D1)
    address internal _pauser;

    // ============ Storage Gap ============

    /// @notice Storage gap for future upgrades
    /// @dev 14 slots consumed (10 + _payoutEndpoint + _payoutPeers +
    ///      _spokeEidByChainId + _pauser), leaving 36 from the 50-slot budget.
    uint256[36] private __gap;
}
