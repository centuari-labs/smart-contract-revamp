// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IWithdrawalRegistry
/// @notice Interface for the WithdrawalRegistry contract — manages the
///         withdrawal state machine with a uniform on-chain HF gate.
/// @dev Every withdrawal (hub-native or cross-chain) passes through this
///      contract. The HF gate (`IRiskModule.canWithdraw`) is the FIRST action
///      in `requestWithdrawal`, ensuring a single enforcement point that closes
///      the collateral-flag loophole for all callers (app users, integrators,
///      direct-contract callers).
///
///      State machine: PENDING → PROCESSING → COMPLETED (or FAILED terminal).
///      Hub-native withdrawals (targetChainId == block.chainid) shortcut
///      directly to COMPLETED via `HubDepositor.payoutDirect`.
interface IWithdrawalRegistry {
    // ============ Enums ============

    enum WithdrawalStatus {
        PENDING,
        PROCESSING,
        COMPLETED,
        FAILED
    }

    // ============ Structs ============

    /// @notice On-chain record for a withdrawal request
    struct WithdrawalRequest {
        address user;
        address asset;
        uint256 amount;
        uint256 targetChainId;
        WithdrawalStatus status;
        uint64 createdAt;
        uint64 updatedAt;
    }

    // ============ Events ============

    /// @notice Emitted when a user requests a withdrawal
    /// @param requestId Unique identifier for this request
    /// @param user The user withdrawing
    /// @param asset The ERC20 token being withdrawn
    /// @param amount The amount being withdrawn
    /// @param targetChainId The chain where tokens should arrive
    event WithdrawalRequested(
        bytes32 indexed requestId,
        address indexed user,
        address indexed asset,
        uint256 amount,
        uint256 targetChainId
    );

    /// @notice Emitted when the operator authorizes a withdrawal for processing
    /// @param requestId The request being authorized
    event WithdrawalAuthorized(bytes32 indexed requestId);

    /// @notice Emitted when a withdrawal completes (tokens delivered to user)
    /// @param requestId The completed request
    event WithdrawalCompleted(bytes32 indexed requestId);

    /// @notice Emitted when a withdrawal fails and the user is refunded
    /// @param requestId The failed request
    event WithdrawalFailed(bytes32 indexed requestId);

    /// @notice Emitted when the operator address is updated
    event OperatorUpdated(
        address indexed previousOperator,
        address indexed newOperator
    );

    /// @notice Emitted when the RiskModule pointer is updated
    event RiskModuleUpdated(
        address indexed previousRiskModule,
        address indexed newRiskModule
    );

    /// @notice Emitted when the HubDepositor pointer is updated
    event HubDepositorUpdated(
        address indexed previousHubDepositor,
        address indexed newHubDepositor
    );

    /// @notice Emitted when the contract is paused
    event Paused(address account);

    /// @notice Emitted when the contract is unpaused
    event Unpaused(address account);

    // ============ Errors ============

    /// @notice Thrown when a zero address is provided
    error ZeroAddress();

    /// @notice Thrown when a zero amount is provided
    error ZeroAmount();

    /// @notice Thrown when the RiskModule rejects the withdrawal
    /// @dev Phase 1 stub: rejects if asset is flagged as collateral.
    ///      Phase 2 real: rejects if post-withdrawal HF < 1.
    error WithdrawalBlockedByHF();

    /// @notice Thrown when referencing a non-existent request
    error InvalidRequestId();

    /// @notice Thrown when a status transition is not allowed
    error InvalidStatusTransition(
        WithdrawalStatus current,
        WithdrawalStatus target
    );

    /// @notice Thrown when an unauthorized caller attempts a restricted action
    error Unauthorized();

    /// @notice Thrown when the contract is paused
    error ContractPaused();

    // ============ User Actions ============

    /// @notice Request a withdrawal of tokens to a target chain
    /// @dev First action is the HF gate: `riskModule.canWithdraw(msg.sender,
    ///      asset, amount)`. Debits `BalanceLedger.available` and records the
    ///      request as PENDING.
    /// @param asset The ERC20 token to withdraw
    /// @param amount The amount to withdraw
    /// @param targetChainId The destination chain (use block.chainid for hub)
    /// @return requestId Unique identifier for tracking this withdrawal
    function requestWithdrawal(
        address asset,
        uint256 amount,
        uint256 targetChainId
    ) external returns (bytes32 requestId);

    // ============ Operator Actions ============

    /// @notice Authorize a pending withdrawal for processing
    /// @dev Hub-native (targetChainId == block.chainid): calls
    ///      `HubDepositor.payoutDirect` and transitions directly to COMPLETED.
    ///      Cross-chain: transitions to PROCESSING (M5 adds LayerZero send).
    /// @param requestId The request to authorize
    function authorize(bytes32 requestId) external;

    /// @notice Mark a PROCESSING withdrawal as completed
    /// @dev Called when cross-chain delivery is confirmed (LZ ack in M5).
    /// @param requestId The request to mark completed
    function markCompleted(bytes32 requestId) external;

    /// @notice Mark a withdrawal as failed and refund the user
    /// @dev Refunds by crediting `BalanceLedger.available`. Accepts requests
    ///      in PENDING or PROCESSING status.
    /// @param requestId The request to mark failed
    function markFailed(bytes32 requestId) external;

    // ============ Governance ============

    /// @notice Update the operator address
    /// @param newOperator The new operator address
    function setOperator(address newOperator) external;

    /// @notice Update the RiskModule pointer (Phase 2 swap point)
    /// @param newRiskModule The new RiskModule address
    function setRiskModule(address newRiskModule) external;

    /// @notice Update the HubDepositor pointer
    /// @param newHubDepositor The new HubDepositor address
    function setHubDepositor(address newHubDepositor) external;

    /// @notice Pause the contract
    function pause() external;

    /// @notice Unpause the contract
    function unpause() external;

    // ============ Views ============

    /// @notice Get the full details of a withdrawal request
    /// @param requestId The request to query
    /// @return The withdrawal request struct
    function getRequest(
        bytes32 requestId
    ) external view returns (WithdrawalRequest memory);

    /// @notice The BalanceLedger this registry interacts with
    function balanceLedger() external view returns (address);

    /// @notice The RiskModule consulted for HF checks
    function riskModule() external view returns (address);

    /// @notice The HubDepositor for hub-native payouts
    function hubDepositor() external view returns (address);

    /// @notice The operator address
    function operator() external view returns (address);

    /// @notice Whether the contract is paused
    function paused() external view returns (bool);
}
