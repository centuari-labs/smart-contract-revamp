// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ICentuari
/// @notice Stub interface for the Centuari contract
/// @dev Settlement calls this interface to settle matched orders.
///      Centuari handles positions (bond tokens, debt) and calls Treasury.settle()
interface ICentuari {
    /// @notice Settle a matched order - handles positions, token transfers, and fees atomically
    /// @dev This function should:
    ///      1. Record lend position and mint bond tokens to lender
    ///      2. Record borrow position (debt) for borrower
    ///      3. Call Treasury.settle() to transfer tokens to borrower and fees to FeeVault
    /// @param matchId The unique match identifier
    /// @param lender The lender address
    /// @param lendOrderId The lend order ID
    /// @param borrower The borrower address
    /// @param borrowOrderId The borrow order ID
    /// @param loanToken The loan token address
    /// @param matchedAmount The matched principal amount
    /// @param rate The interest rate in basis points
    /// @param maturity The maturity timestamp
    function settleMatch(
        bytes32 matchId,
        address lender,
        bytes32 lendOrderId,
        address borrower,
        bytes32 borrowOrderId,
        address loanToken,
        uint256 matchedAmount,
        uint256 rate,
        uint256 maturity
    ) external;
}
