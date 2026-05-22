// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

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

    /// @notice Markets where a borrower currently has non-zero debt
    /// @dev borrower => set of marketIds. Maintained in lockstep with
    ///      `_activeDebtCount` (add on debt 0→non-zero in settleMatch, remove on
    ///      non-zero→0 in repay) so the RiskModule can enumerate and value a
    ///      user's total debt across markets on-chain. Append-only (Phase 3, C6).
    mapping(address => EnumerableSet.Bytes32Set) internal _borrowerMarkets;

    /// @notice Loan token for a given marketId (= keccak256(loanToken, maturity))
    /// @dev Set when a market is first seen post-upgrade; lets `getBorrowerDebts`
    ///      resolve a marketId back to its loan token without off-chain data.
    ///      Append-only (Phase 3, C6).
    mapping(bytes32 => address) internal _marketLoanToken;

    // ============ Storage Gap ============

    /// @notice Storage gap for future upgrades
    /// @dev Reduced 40 → 38 in Phase 3 (C6) when `_borrowerMarkets` +
    ///      `_marketLoanToken` were appended (2 mapping slots). When adding new
    ///      variables, reduce this gap accordingly.
    ///      Current usage: address/bool slots (settlement, balanceLedger+paused,
    ///      bondTokenFactory, operator, feeCollector) + 6 mappings (marketTotalCbt,
    ///      lendPositionCbtAmount, borrowDebt, activeDebtCount, borrowerMarkets,
    ///      marketLoanToken).
    uint256[38] private __gap;
}
