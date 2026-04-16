// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IHubIntentSettler
/// @notice Interface for the HubIntentSettler contract — processes solver fills
///         for cross-chain deposits arriving from spoke chains.
/// @dev In M4, `fillFor` is operator-gated (the solver calls through the
///      protocol operator key). In M5, the operator gate is replaced by
///      LayerZero proof verification so the solver can call directly with an
///      LZ-attested deposit proof from the source spoke.
///
///      Token custody: this contract holds the actual ERC20 tokens that solvers
///      transfer in during `fillFor`. Tokens are released to solvers via
///      `releaseToSolver`, callable only by the SettlementLedger after the
///      Sweeper Bot bridges spoke tokens to hub and calls `matchAndReimburse`.
interface IHubIntentSettler {
    // ============ Enums ============

    /// @notice Status of a cross-chain deposit
    /// @dev NONE (0) is the default for uninitialized mapping entries,
    ///      ensuring unprocessed deposits are correctly identified.
    ///      CREDITED is used by the M5 LayerZero-confirmed credit path
    ///      (`confirmDeposit`) — it is mutually exclusive with FILLED
    ///      (the dormant Phase 1 solver path) and is set once per depositId
    ///      to prevent replay of hub-side credits.
    enum DepositStatus {
        NONE,
        FILLED,
        NO_FILL,
        CREDITED
    }

    // ============ Events ============

    /// @notice Emitted when a solver successfully fills a cross-chain deposit
    /// @param depositId Unique identifier from the spoke DepositInitiated event
    /// @param solver The solver who fronted the capital
    /// @param user The user whose BalanceLedger.available was credited
    /// @param asset The ERC20 token deposited
    /// @param amount The amount credited
    /// @param sourceChainId The spoke chain where the deposit originated
    event SolverFillRegistered(
        bytes32 indexed depositId,
        address indexed solver,
        address indexed user,
        address asset,
        uint256 amount,
        uint256 sourceChainId
    );

    /// @notice Emitted when a deposit is marked as unfilled (no solver picked it up)
    /// @param depositId The deposit that was not filled
    event DepositMarkedNoFill(bytes32 indexed depositId);

    /// @notice Emitted when a LayerZero-confirmed deposit credits the user
    /// @param depositId Deterministic id from the spoke gateway
    /// @param user The user whose BalanceLedger.available was credited
    /// @param asset The ERC20 token credited
    /// @param amount The amount credited
    /// @param sourceChainId The spoke chain where the deposit originated
    /// @param classification 1 = BRIDGED, 2 = SPOKE_NATIVE
    event DepositConfirmed(
        bytes32 indexed depositId,
        address indexed user,
        address asset,
        uint256 amount,
        uint256 sourceChainId,
        uint8 classification
    );

    /// @notice Emitted when the LZ endpoint pointer is updated
    event LzEndpointUpdated(address indexed endpoint);

    /// @notice Emitted when a trusted remote is set for a spoke eid
    event TrustedRemoteSet(uint32 indexed eid, bytes32 peer);

    /// @notice Emitted when the WithdrawalRegistry pointer is updated
    event WithdrawalRegistryUpdated(address indexed registry);

    /// @notice Emitted when the operator address is updated
    event OperatorUpdated(
        address indexed previousOperator,
        address indexed newOperator
    );

    /// @notice Emitted when the SettlementLedger pointer is updated
    event SettlementLedgerUpdated(
        address indexed previousSettlementLedger,
        address indexed newSettlementLedger
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

    /// @notice Thrown when attempting to process an already-processed deposit
    error DepositAlreadyProcessed(bytes32 depositId);

    /// @notice Thrown when an unauthorized caller attempts a restricted action
    error Unauthorized();

    /// @notice Thrown when the contract is paused
    error ContractPaused();

    /// @notice Thrown when `lzReceive` is called by a non-endpoint address
    error InvalidLzEndpoint();

    /// @notice Thrown when the LZ origin sender does not match the trusted remote
    error UntrustedRemote(uint32 eid, bytes32 sender);

    // ============ Operator/Solver Actions ============

    /// @notice Fill a cross-chain deposit on behalf of a user
    /// @dev M4: operator-gated. M5: LZ-proof replaces operator gate.
    ///      Pulls tokens from the caller via `safeTransferFrom`, credits the
    ///      user's BalanceLedger.available, and registers a reimbursement
    ///      obligation on the SettlementLedger.
    /// @param depositId Unique deposit identifier from the spoke
    /// @param user The user to credit on the hub
    /// @param asset The ERC20 token being deposited
    /// @param amount The amount to credit
    /// @param sourceChainId The spoke chain where the deposit originated
    function fillFor(
        bytes32 depositId,
        address user,
        address asset,
        uint256 amount,
        uint256 sourceChainId
    ) external;

    /// @notice Mark a deposit as unfilled after the fill window expires
    /// @dev Callable by the operator/keeper. In M5, this also dispatches a
    ///      LayerZero proof-of-non-fill message back to the spoke so the user
    ///      can reclaim their escrowed tokens.
    /// @param depositId The deposit to mark as unfilled
    function markNoFill(bytes32 depositId) external;

    /// @notice Release tokens to a solver (reimbursement)
    /// @dev Only callable by the SettlementLedger after `matchAndReimburse`.
    /// @param solver The solver to reimburse
    /// @param asset The ERC20 token to release
    /// @param amount The amount to release
    function releaseToSolver(
        address solver,
        address asset,
        uint256 amount
    ) external;

    // ============ Governance ============

    /// @notice Update the operator address
    /// @param newOperator The new operator address
    function setOperator(address newOperator) external;

    /// @notice Update the SettlementLedger pointer
    /// @param newSettlementLedger The new SettlementLedger address
    function setSettlementLedger(address newSettlementLedger) external;

    /// @notice Pause the contract
    function pause() external;

    /// @notice Unpause the contract
    function unpause() external;

    // ============ M5 LZ administration ============

    /// @notice Set the LayerZero V2 endpoint on the hub (owner-only).
    function setLzEndpoint(address endpoint) external;

    /// @notice Set the trusted remote spoke peer for an eid (owner-only).
    function setTrustedRemote(uint32 eid, bytes32 peer) external;

    /// @notice Set the WithdrawalRegistry pointer (owner-only).
    function setWithdrawalRegistry(address registry) external;

    // ============ Views ============

    /// @notice The LZ V2 endpoint on the hub
    function lzEndpoint() external view returns (address);

    /// @notice The trusted remote peer for a given eid
    function trustedRemote(uint32 eid) external view returns (bytes32);

    /// @notice The WithdrawalRegistry pointer
    function withdrawalRegistry() external view returns (address);

    /// @notice Get the status of a deposit
    /// @param depositId The deposit to query
    /// @return The current status (NONE if unprocessed)
    function depositStatus(
        bytes32 depositId
    ) external view returns (DepositStatus);

    /// @notice The BalanceLedger this settler credits
    function balanceLedger() external view returns (address);

    /// @notice The SettlementLedger for solver reimbursement tracking
    function settlementLedger() external view returns (address);

    /// @notice The operator address
    function operator() external view returns (address);

    /// @notice Whether the contract is paused
    function paused() external view returns (bool);
}
