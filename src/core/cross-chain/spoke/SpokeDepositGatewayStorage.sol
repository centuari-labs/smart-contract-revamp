// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISpokeDepositGateway} from "../../../interfaces/cross-chain/spoke/ISpokeDepositGateway.sol";
import {ISpokeVaultStable} from "../../../interfaces/cross-chain/spoke/ISpokeVaultStable.sol";

/// @title SpokeDepositGatewayStorage
/// @notice Storage layout for the upgradeable SpokeDepositGateway contract.
/// @dev IMPORTANT: Only append new storage variables to the end. Never reorder,
///      remove, or change the type of an existing variable. Reduce the
///      `__gap` by exactly the number of slots consumed when extending.
abstract contract SpokeDepositGatewayStorage {
    // ============ Pending deposits ============

    /// @notice depositId -> persisted state for in-flight or refunded deposits.
    mapping(bytes32 => ISpokeDepositGateway.PendingDeposit) internal _pendingDeposits;

    /// @notice Per-user nonce used to derive deterministic depositIds.
    mapping(address => uint256) internal _userNonce;

    /// @notice Routing classification per registered asset (mirrors the vault).
    mapping(address => ISpokeVaultStable.AssetClassification) internal _classifications;

    // ============ Wiring ============

    /// @notice The SpokeVaultStable that holds escrowed tokens for this spoke.
    address internal _vault;

    /// @notice The LayerZero V2 endpoint on this spoke chain.
    address internal _endpoint;

    /// @notice Destination LayerZero eid for the hub (Arbitrum).
    uint32 internal _hubEid;

    /// @notice eid -> peer (`HubIntentSettler` or equivalent) as bytes32.
    mapping(uint32 => bytes32) internal _peers;

    // ============ Storage Gap ============

    /// @notice Storage gap for future upgrades.
    /// @dev Seven slots consumed (3 mappings + vault + endpoint + hubEid + peers
    ///      mapping), leaving 43 from the original 50-slot budget.
    uint256[43] private __gap;
}
