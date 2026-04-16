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

    /// @notice Emitted when chain liquidity is incremented by a confirmed
    ///         SPOKE_NATIVE deposit.
    event ChainLiquidityIncremented(
        address indexed asset,
        uint256 indexed chainId,
        uint256 amount,
        uint256 newTotal
    );

    /// @notice Emitted when chain liquidity is decremented by a SPOKE_NATIVE
    ///         withdrawal request.
    event ChainLiquidityDecremented(
        address indexed asset,
        uint256 indexed chainId,
        uint256 amount,
        uint256 newTotal
    );

    /// @notice Emitted when the HubIntentSettler pointer is updated.
    event HubIntentSettlerUpdated(address indexed settler);

    /// @notice Emitted when a spoke-native route flag is set.
    event SpokeNativeRouteSet(
        address indexed asset,
        uint256 indexed chainId,
        bool enabled
    );

    /// @notice Emitted when a payout message is dispatched via LZ to a spoke.
    event PayoutDispatched(
        bytes32 indexed requestId,
        uint256 indexed targetChainId,
        bytes32 lzGuid
    );

    /// @notice Emitted when the payout endpoint is updated.
    event PayoutEndpointUpdated(address indexed endpoint);

    /// @notice Emitted when a payout peer is set.
    event PayoutPeerSet(uint32 indexed eid, bytes32 peer);

    /// @notice Emitted when a spoke eid mapping is set.
    event SpokeEidSet(uint256 indexed chainId, uint32 eid);

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

    /// @notice Thrown when the LZ endpoint is not configured.
    error PayoutEndpointNotSet();

    /// @notice Thrown when the spoke eid is not mapped for a target chain.
    error SpokeEidNotMapped(uint256 chainId);

    /// @notice Thrown when the payout peer is not set for the spoke eid.
    error PayoutPeerNotSet(uint32 eid);

    /// @notice Thrown when a SPOKE_NATIVE withdrawal exceeds chain liquidity
    error InsufficientChainLiquidity(
        address asset,
        uint256 chainId,
        uint256 available,
        uint256 requested
    );

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

    /// @notice Authorize a pending withdrawal for processing.
    /// @dev Hub-native (targetChainId == block.chainid): calls
    ///      `HubDepositor.payoutDirect` and transitions directly to COMPLETED.
    ///      Cross-chain: dispatches a LayerZero payout message to the spoke's
    ///      `SpokePayout` and transitions to PROCESSING. The operator must
    ///      supply the LZ native fee via `msg.value`.
    /// @param requestId The request to authorize
    function authorize(bytes32 requestId) external payable;

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

    /// @notice Increment chain liquidity for a SPOKE_NATIVE deposit.
    ///         Callable only by the HubIntentSettler.
    function incrementChainLiquidity(
        address asset,
        uint256 chainId,
        uint256 amount
    ) external;

    /// @notice Set the HubIntentSettler pointer (owner-only).
    function setHubIntentSettler(address settler) external;

    /// @notice Mark/unmark an (asset, chainId) pair as a spoke-native route
    ///         for the chain-liquidity capacity gate (owner-only).
    function setSpokeNativeRoute(
        address asset,
        uint256 chainId,
        bool enabled
    ) external;

    /// @notice Set the LZ endpoint for payout dispatch (owner-only).
    function setPayoutEndpoint(address endpoint) external;

    /// @notice Set the SpokePayout peer for a given eid (owner-only).
    function setPayoutPeer(uint32 eid, bytes32 peer) external;

    /// @notice Map an EIP-155 chainId to a LZ eid (owner-only).
    function setSpokeEid(uint256 chainId, uint32 eid) external;

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

    /// @notice Physical chain liquidity for a (token, chainId) pair.
    function chainLiquidity(
        address asset,
        uint256 chainId
    ) external view returns (uint256);

    /// @notice Whether (asset, chainId) is flagged as a spoke-native route.
    function isSpokeNativeRoute(
        address asset,
        uint256 chainId
    ) external view returns (bool);

    /// @notice The HubIntentSettler allowed to increment chain liquidity.
    function hubIntentSettler() external view returns (address);

    /// @notice The LZ endpoint for payout dispatch.
    function payoutEndpoint() external view returns (address);

    /// @notice The SpokePayout peer for a given eid.
    function payoutPeer(uint32 eid) external view returns (bytes32);

    /// @notice The LZ eid for a given EIP-155 chainId.
    function spokeEidByChainId(uint256 chainId) external view returns (uint32);
}
