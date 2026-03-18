// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IWithdrawalRegistry
/// @notice Manages withdrawal requests with sequential enforcement and SLA
/// @dev SpokePayout cannot release tokens until recall is confirmed complete (Invariant #4).
///      MAX_WITHDRAWAL_QUEUE_HOURS = 4 with escalation path.
interface IWithdrawalRegistry {
    // ============ Enums ============

    enum WithdrawalState {
        PENDING,
        PROCESSING,
        COMPLETED,
        ESCALATED
    }

    // ============ Structs ============

    struct WithdrawalRequest {
        address user;
        address asset;
        uint256 amount;
        uint256 requestedAt;
        uint256 targetChainId;
        WithdrawalState state;
    }

    // ============ Constants ============

    function MAX_WITHDRAWAL_QUEUE_HOURS() external pure returns (uint256); // 4

    // ============ Core Functions ============

    /// @notice Request a withdrawal
    /// @dev If available balance is sufficient, processes instantly.
    ///      Otherwise queues and triggers YieldRouter recall.
    /// @param asset The asset to withdraw
    /// @param amount The amount to withdraw
    /// @param targetChainId The destination chain (0 for hub/Arbitrum)
    /// @return requestId The withdrawal request ID
    function requestWithdrawal(
        address asset,
        uint256 amount,
        uint256 targetChainId
    ) external returns (bytes32 requestId);

    /// @notice Authorize SpokePayout to release funds (called after recall completes)
    /// @param requestId The withdrawal request ID
    function authorize(bytes32 requestId) external;

    /// @notice Mark withdrawal as completed
    /// @param requestId The withdrawal request ID
    function complete(bytes32 requestId) external;

    /// @notice Escalate a withdrawal that exceeded the SLA
    /// @param requestId The withdrawal request ID
    function escalate(bytes32 requestId) external;

    // ============ View Functions ============

    function getRequest(bytes32 requestId) external view returns (WithdrawalRequest memory);
    function isAuthorized(bytes32 requestId) external view returns (bool);

    // ============ Events ============

    event WithdrawalRequested(bytes32 indexed requestId, address indexed user, address indexed asset, uint256 amount, uint256 targetChainId);
    event WithdrawalAuthorized(bytes32 indexed requestId);
    event WithdrawalCompleted(bytes32 indexed requestId);
    event WithdrawalEscalated(bytes32 indexed requestId, uint256 queuedDuration);

    // ============ Errors ============

    error Unauthorized();
    error ZeroAddress();
    error ZeroAmount();
    error InvalidState(bytes32 requestId, WithdrawalState current, WithdrawalState expected);
    error WithdrawalNotFound(bytes32 requestId);
}
