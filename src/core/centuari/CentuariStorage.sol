// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

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

    /// @notice The BalanceLedger contract for balance accounting
    /// @dev Centuari calls BalanceLedger for all credit/debit operations
    address internal _balanceLedger;

    /// @notice Whether the contract is paused
    /// @dev When paused, settlement functions are disabled
    bool internal _paused;

    /// @notice Total CBT minted per market
    /// @dev marketId = keccak256(abi.encode(loanToken, maturity))
    mapping(bytes32 => uint256) internal _marketTotalCbt;

    /// @notice Lender CBT amount per market and address
    /// @dev marketId => lender => cbtAmount
    mapping(bytes32 => mapping(address => uint256)) internal _lendPositionCbtAmount;

    /// @notice Borrow debt by market ID and user address
    /// @dev marketId => user => debt (principal + interest)
    mapping(bytes32 => mapping(address => uint256)) internal _borrowDebt;

    /// @notice The address of the Bond Token Factory contract
    /// @dev Factory deploys ERC20 bond tokens for each market
    address internal _bondTokenFactory;

    /// @notice The address of the operator (backend)
    /// @dev Only the operator can call repay
    address internal _operator;

    /// @notice Count of markets where a user has non-zero debt
    /// @dev Incremented when _borrowDebt[marketId][user] goes 0→non-zero,
    ///      decremented when it goes non-zero→0. Used by repay() to trigger
    ///      auto-unflag of all collateral when user is fully debt-free.
    mapping(address => uint256) internal _activeDebtCount;

    /// @notice Address that receives protocol fee credits in BalanceLedger
    /// @dev Settlement fees and trade fees are credited to this address
    address internal _feeCollector;

    // ============ Storage Gap ============

    /// @notice Storage gap for future upgrades
    /// @dev Provides 40 slots for future storage variables.
    ///      When adding new variables, reduce this gap accordingly.
    ///      Current usage: 5 slots (settlement, balanceLedger, paused, bondTokenFactory, operator, feeCollector)
    ///      + 4 mappings (marketTotalCbt, lendPositionCbtAmount, borrowDebt, activeDebtCount)
    uint256[40] private __gap;
}
