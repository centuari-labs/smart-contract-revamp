// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title SettlementStorage
/// @notice Storage layout for the upgradeable Settlement contract
/// @dev This contract defines the storage layout for Settlement.
///      IMPORTANT: Only append new storage variables to the end.
///      Never reorder, remove, or change types of existing variables.
abstract contract SettlementStorage {
    // ============ Storage Variables ============

    /// @notice The address of the settlement engine operator
    /// @dev Only this address can call settleMatches/settleMatch
    address internal _operator;

    /// @notice The address of the Centuari contract
    /// @dev Settlement calls Centuari.settleMatch() for each match
    address internal _centuari;

    /// @notice Whether the contract is paused
    /// @dev When paused, settlement functions are disabled
    bool internal _paused;

    /// @notice Mapping of match IDs to their settlement status
    /// @dev Used to prevent double-settlement of the same match
    mapping(bytes32 => bool) internal _settledMatches;

    /// @notice Guardian allowed to pause()/unpause() with no timelock delay.
    /// @dev Separate from owner() so the emergency stop stays fast while owner()
    ///      (a 24h TimelockController in production) governs every other setter.
    ///      Set to owner_ at initialize; rotated via setPauser (onlyOwner). (D1)
    address internal _pauser;

    // ============ Storage Gap ============

    /// @notice Storage gap for future upgrades
    /// @dev Reduced 47 → 46 in D1 when `_pauser` was appended.
    ///      When adding new variables, reduce this gap accordingly
    uint256[46] private __gap;
}
