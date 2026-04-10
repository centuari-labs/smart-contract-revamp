// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title HubDepositorStorage
/// @notice Storage layout for the upgradeable HubDepositor contract
/// @dev IMPORTANT: Only append new storage variables to the end.
///      Never reorder, remove, or change types of existing variables.
abstract contract HubDepositorStorage {
    // ============ Storage Variables ============

    /// @notice The BalanceLedger this depositor writes to
    /// @dev Set once at initialization. HubDepositor must be registered as an
    ///      authorized writer on BalanceLedger before any deposit can succeed.
    address internal _balanceLedger;

    // ============ Storage Gap ============

    /// @notice Storage gap for future upgrades
    /// @dev Provides 49 slots for future storage variables. One slot consumed
    ///      by `_balanceLedger`, leaving 49 from the original 50-slot budget.
    uint256[49] private __gap;
}
