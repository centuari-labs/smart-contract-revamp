// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ICentuari} from "../interfaces/ICentuari.sol";

/// @title CentuariStorage
/// @notice Storage layout for the upgradeable Centuari contract
/// @dev This contract defines the storage layout for Centuari.
///      IMPORTANT: Only append new storage variables to the end.
///      Never reorder, remove, or change types of existing variables.
abstract contract CentuariStorage {
    // ============ Constants ============

    /// @notice Basis points precision (100% = 10000)
    uint256 internal constant RATE_PRECISION = 10000;

    /// @notice Seconds in a year (365 days)
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    // ============ Storage Variables ============

    /// @notice The address of the Settlement contract
    /// @dev Only Settlement can call settleMatch
    address internal _settlement;

    /// @notice The address of the Treasury contract
    /// @dev Centuari calls Treasury for token transfers
    address internal _treasury;

    /// @notice Whether the contract is paused
    /// @dev When paused, settlement functions are disabled
    bool internal _paused;

    /// @notice Market state by market ID
    /// @dev marketId = keccak256(abi.encode(loanToken, maturity))
    mapping(bytes32 => ICentuari.Market) internal _markets;

    /// @notice Lend positions by market ID and user address
    /// @dev marketId => user => LendPosition
    mapping(bytes32 => mapping(address => ICentuari.LendPosition)) internal _lendPositions;

    /// @notice Borrow positions by market ID and user address
    /// @dev marketId => user => BorrowPosition
    mapping(bytes32 => mapping(address => ICentuari.BorrowPosition)) internal _borrowPositions;

    // ============ Storage Gap ============

    /// @notice Storage gap for future upgrades
    /// @dev Provides 44 slots for future storage variables.
    ///      When adding new variables, reduce this gap accordingly.
    ///      Current usage: 3 slots (settlement, treasury, paused) + 3 mappings
    uint256[44] private __gap;
}
