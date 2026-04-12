// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IHubIntentSettler} from "../../interfaces/cross-chain/IHubIntentSettler.sol";

/// @title HubIntentSettlerStorage
/// @notice Storage layout for the upgradeable HubIntentSettler contract
/// @dev IMPORTANT: Only append new storage variables to the end.
///      Never reorder, remove, or change types of existing variables.
abstract contract HubIntentSettlerStorage {
    // ============ Storage Variables ============

    /// @notice The BalanceLedger this settler credits on fill
    address internal _balanceLedger;

    /// @notice The SettlementLedger for solver reimbursement tracking
    /// @dev Set post-deployment by governance via `setSettlementLedger`
    ///      because of the circular deploy dependency.
    address internal _settlementLedger;

    /// @notice The operator address (solver in M4, LZ-gated in M5)
    address internal _operator;

    /// @notice Whether the contract is paused
    bool internal _paused;

    /// @notice Deposit processing status keyed by depositId
    /// @dev Default value (0) maps to DepositStatus.NONE, meaning unprocessed.
    mapping(bytes32 => IHubIntentSettler.DepositStatus)
        internal _depositStatuses;

    // ============ Storage Gap ============

    /// @notice Storage gap for future upgrades
    /// @dev 5 slots consumed, leaving 45 from the 50-slot budget.
    uint256[45] private __gap;
}
