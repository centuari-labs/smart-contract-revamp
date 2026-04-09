// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ISettlementLedger
/// @notice Async solver reimbursement tracking
/// @dev Records solver fills. When Sweeper bridges real tokens, matches against pending fills.
interface ISettlementLedger {
    /// @notice Register a solver fill for future reimbursement (without asset tracking)
    /// @dev DEPRECATED: Use registerWithAsset() instead for proper reimbursement.
    function register(bytes32 orderId, address solver, uint256 amount) external;

    /// @notice P1-9: Register a solver fill WITH asset address for proper reimbursement
    /// @param orderId The ERC-7683 order identifier
    /// @param solver The solver that fronted capital
    /// @param asset The token address (needed for matchFill to transfer correct token)
    /// @param amount The amount fronted
    function registerWithAsset(bytes32 orderId, address solver, address asset, uint256 amount) external;

    /// @notice Match bridged tokens to a pending solver fill — triggers reimbursement
    /// @param orderId The order to match against
    /// @param bridgedAmount The amount of real tokens bridged from spoke
    function matchFill(bytes32 orderId, uint256 bridgedAmount) external;

    /// @notice Check if an order has a pending reimbursement
    function isPending(bytes32 orderId) external view returns (bool);

    /// @notice Get pending reimbursement details
    function getPendingFill(bytes32 orderId) external view returns (address solver, uint256 amount);

    // ============ Events ============

    event FillRegistered(bytes32 indexed orderId, address indexed solver, uint256 amount);
    event FillMatched(bytes32 indexed orderId, address indexed solver, uint256 amount);

    // ============ Errors ============

    error Unauthorized();
    error OrderAlreadyRegistered(bytes32 orderId);
    error OrderNotFound(bytes32 orderId);
    error AmountMismatch(uint256 expected, uint256 provided);
}
