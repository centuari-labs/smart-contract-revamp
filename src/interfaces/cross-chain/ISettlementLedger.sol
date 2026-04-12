// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ISettlementLedger
/// @notice Interface for the SettlementLedger contract — tracks solver
///         reimbursement obligations for cross-chain deposits.
/// @dev Pure accounting contract. Does NOT hold tokens. When `matchAndReimburse`
///      is called by the Sweeper Bot (after bridging spoke tokens to hub), it
///      calls `HubIntentSettler.releaseToSolver` to transfer tokens from the
///      HubIntentSettler's custody to the solver's EOA.
///
///      State machine per depositId: NONE → REGISTERED → REIMBURSED.
///      Only HubIntentSettler can call `register`. Only the operator (Sweeper)
///      can call `matchAndReimburse`.
interface ISettlementLedger {
    // ============ Enums ============

    /// @notice Reimbursement status for a solver fill
    /// @dev NONE (0) is the default for uninitialized mapping entries.
    enum ReimbursementStatus {
        NONE,
        REGISTERED,
        REIMBURSED
    }

    // ============ Structs ============

    /// @notice On-chain record for a solver reimbursement obligation
    struct ReimbursementRecord {
        address solver;
        address asset;
        uint256 amount;
        ReimbursementStatus status;
    }

    // ============ Events ============

    /// @notice Emitted when HubIntentSettler registers a solver fill
    /// @param depositId The cross-chain deposit that was filled
    /// @param solver The solver who fronted capital
    /// @param asset The ERC20 token
    /// @param amount The amount owed to the solver
    event ReimbursementRegistered(
        bytes32 indexed depositId,
        address indexed solver,
        address asset,
        uint256 amount
    );

    /// @notice Emitted when the Sweeper Bot reimburses a solver
    /// @param depositId The deposit whose solver was reimbursed
    /// @param solver The solver who received reimbursement
    /// @param asset The ERC20 token
    /// @param amount The amount reimbursed
    event ReimbursementCompleted(
        bytes32 indexed depositId,
        address indexed solver,
        address asset,
        uint256 amount
    );

    /// @notice Emitted when the operator address is updated
    event OperatorUpdated(
        address indexed previousOperator,
        address indexed newOperator
    );

    /// @notice Emitted when the HubIntentSettler pointer is updated
    event HubIntentSettlerUpdated(
        address indexed previousHubIntentSettler,
        address indexed newHubIntentSettler
    );

    // ============ Errors ============

    /// @notice Thrown when a zero address is provided
    error ZeroAddress();

    /// @notice Thrown when a zero amount is provided
    error ZeroAmount();

    /// @notice Thrown when attempting to register an already-registered deposit
    error AlreadyRegistered(bytes32 depositId);

    /// @notice Thrown when referencing a deposit that was not registered
    error NotRegistered(bytes32 depositId);

    /// @notice Thrown when the record is in an unexpected status
    error InvalidStatus(
        bytes32 depositId,
        ReimbursementStatus current
    );

    /// @notice Thrown when an unauthorized caller attempts a restricted action
    error Unauthorized();

    // ============ HubIntentSettler Actions ============

    /// @notice Register a solver reimbursement obligation
    /// @dev Only callable by HubIntentSettler during `fillFor`.
    /// @param depositId The cross-chain deposit that was filled
    /// @param solver The solver to reimburse
    /// @param asset The ERC20 token
    /// @param amount The amount owed
    function register(
        bytes32 depositId,
        address solver,
        address asset,
        uint256 amount
    ) external;

    // ============ Operator Actions ============

    /// @notice Reimburse a solver after the Sweeper bridges spoke tokens to hub
    /// @dev Transitions REGISTERED → REIMBURSED and calls
    ///      `HubIntentSettler.releaseToSolver` to transfer tokens.
    /// @param depositId The deposit whose solver should be reimbursed
    function matchAndReimburse(bytes32 depositId) external;

    // ============ Governance ============

    /// @notice Update the operator address (Sweeper Bot)
    /// @param newOperator The new operator address
    function setOperator(address newOperator) external;

    /// @notice Update the HubIntentSettler pointer
    /// @param newHubIntentSettler The new HubIntentSettler address
    function setHubIntentSettler(address newHubIntentSettler) external;

    // ============ Views ============

    /// @notice Get the reimbursement record for a deposit
    /// @param depositId The deposit to query
    /// @return The reimbursement record
    function getRecord(
        bytes32 depositId
    ) external view returns (ReimbursementRecord memory);

    /// @notice The HubIntentSettler that calls register()
    function hubIntentSettler() external view returns (address);

    /// @notice The operator address (Sweeper Bot)
    function operator() external view returns (address);
}
