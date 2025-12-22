// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ITreasury
/// @notice Interface for the Treasury contract that handles token transfers
/// @dev Treasury manages deposits, withdrawals, and settlement transfers.
///      Centuari calls this interface to execute token transfers during settlement.
interface ITreasury {
    // ============ Events ============

    /// @notice Emitted when a settlement transfer is executed
    /// @param loanToken The loan token address
    /// @param from The address funds are transferred from (lender's deposit)
    /// @param to The address funds are transferred to (borrower)
    /// @param amount The principal amount transferred
    /// @param fee The fee amount collected
    event SettlementExecuted(
        address indexed loanToken,
        address indexed from,
        address indexed to,
        uint256 amount,
        uint256 fee
    );

    // ============ Errors ============

    /// @notice Thrown when caller is not authorized
    error Unauthorized();

    /// @notice Thrown when a zero address is provided
    error ZeroAddress();

    /// @notice Thrown when an invalid amount is provided
    error InvalidAmount();

    /// @notice Thrown when there are insufficient funds
    error InsufficientFunds();

    // ============ Core Functions ============

    /// @notice Execute a settlement transfer
    /// @dev Called by Centuari during match settlement.
    ///      Transfers funds from lender's deposit to borrower and collects fees.
    /// @param loanToken The loan token address
    /// @param from The lender address (funds come from their deposit)
    /// @param to The borrower address (receives the loan)
    /// @param amount The principal amount to transfer
    /// @param fee The fee amount to collect
    function settle(
        address loanToken,
        address from,
        address to,
        uint256 amount,
        uint256 fee
    ) external;
}
