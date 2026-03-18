// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IHubIntentSettler
/// @notice ERC-7683 hub side — credits BalanceLedger when solver fills a cross-chain deposit
/// @dev Security Invariant #6: fillFor() requires actual token transfer before crediting BalanceLedger.
interface IHubIntentSettler {
    /// @notice Solver fills a cross-chain deposit intent on the hub
    /// @dev Requires actual token transfer from solver (balanceOf check before/after)
    /// @param orderId The ERC-7683 order identifier
    /// @param user The depositing user
    /// @param asset The deposited asset
    /// @param amount The deposit amount
    function fillFor(
        bytes32 orderId,
        address user,
        address asset,
        uint256 amount
    ) external;

    // ============ Events ============

    event SolverFillRegistered(bytes32 indexed orderId, address indexed solver, address indexed user, address asset, uint256 amount);

    // ============ Errors ============

    error Unauthorized();
    error InsufficientTransfer(uint256 expected, uint256 received);
    error ZeroAddress();
    error ZeroAmount();
}
