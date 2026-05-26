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

    /// @notice Max distinct debt markets a single borrower may hold (SC-5)
    /// @dev Bounds the RiskModule's on-chain HF loop (one oracle call per market)
    ///      so a borrower can never push their own withdraw/unflag gas past the
    ///      block limit. The (MAX_DEBT_MARKETS+1)th new-market settlement reverts
    ///      with TooManyDebtMarkets.
    uint256 internal constant MAX_DEBT_MARKETS = 64;

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

    /// @notice DEPRECATED (SC-8) — retained only to preserve the storage layout
    /// @dev Was a hand-maintained parallel counter of a borrower's non-zero-debt
    ///      markets. It is no longer read or written: activeDebtCount() now derives
    ///      from `_borrowerMarkets[user].length()` (single source of truth), which
    ///      seedBorrowerMarkets keeps correct automatically. The slot stays declared
    ///      because storage is append-only — do not remove it.
    ///      NOTE: an earlier comment here claimed repay() auto-unflags collateral
    ///      when debt-free. That was never true — repay() never touches collateral
    ///      flags; users unflag explicitly via CollateralManager.unflagFor.
    mapping(address => uint256) internal _activeDebtCount;

    /// @notice Address that receives protocol fee credits in BalanceLedger
    /// @dev Settlement fees and trade fees are credited to this address
    address internal _feeCollector;

    /// @notice Markets where a borrower currently has non-zero debt
    /// @dev borrower => set of marketIds. Single source of truth for a borrower's
    ///      active debt markets: add on debt 0→non-zero in settleMatch, remove on
    ///      non-zero→0 in repay, and reconcile pre-upgrade positions via
    ///      seedBorrowerMarkets. The RiskModule enumerates and values a user's
    ///      total debt across markets on-chain from this set, and activeDebtCount()
    ///      returns its length (SC-8). Append-only (Phase 3, C6).
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
