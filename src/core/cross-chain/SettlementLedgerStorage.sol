// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISettlementLedger} from "../../interfaces/cross-chain/ISettlementLedger.sol";

/// @title SettlementLedgerStorage
/// @notice Storage layout for the upgradeable SettlementLedger contract
/// @dev IMPORTANT: Only append new storage variables to the end.
///      Never reorder, remove, or change types of existing variables.
abstract contract SettlementLedgerStorage {
    // ============ Storage Variables ============

    /// @notice The HubIntentSettler that is the sole caller of `register()`
    address internal _hubIntentSettler;

    /// @notice The operator address (Sweeper Bot)
    address internal _operator;

    /// @notice Reimbursement records keyed by depositId
    /// @dev Default value (0) maps to ReimbursementStatus.NONE.
    mapping(bytes32 => ISettlementLedger.ReimbursementRecord)
        internal _records;

    // ============ Storage Gap ============

    /// @notice Storage gap for future upgrades
    /// @dev 3 slots consumed, leaving 47 from the 50-slot budget.
    uint256[47] private __gap;
}
