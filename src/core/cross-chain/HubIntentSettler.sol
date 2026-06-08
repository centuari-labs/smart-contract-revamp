// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IHubIntentSettler} from "../../interfaces/cross-chain/IHubIntentSettler.sol";
import {IBalanceLedger} from "../../interfaces/IBalanceLedger.sol";
import {ISettlementLedger} from "../../interfaces/cross-chain/ISettlementLedger.sol";
import {IWithdrawalRegistry} from "../../interfaces/cross-chain/IWithdrawalRegistry.sol";
import {HubIntentSettlerStorage} from "./HubIntentSettlerStorage.sol";
import {ReentrancyGuardUpgradeable} from "../../utils/ReentrancyGuardUpgradeable.sol";

/// @title HubIntentSettler
/// @notice Processes solver fills for cross-chain deposits arriving from spoke
///         chains. Credits the user's BalanceLedger.available and registers a
///         reimbursement obligation on the SettlementLedger.
/// @dev Token custody: this contract holds the actual ERC20 tokens that solvers
///      transfer in during `fillFor`. Tokens stay here until the SettlementLedger
///      calls `releaseToSolver` after the Sweeper Bot bridges spoke tokens and
///      confirms reimbursement.
///
///      M4: operator-gated (solver calls through the protocol operator key).
///      M5: the operator gate on `fillFor` is replaced by LayerZero proof
///      verification so the solver can call directly.
/// @custom:audit-scope OUT OF AUDIT SCOPE (hub-only launch) — cross-chain deposit
///      credit path; dormant (no spoke deposits arrive on the hub-only path). See dev-docs/audit/SCOPE.md §4.
contract HubIntentSettler is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    HubIntentSettlerStorage,
    IHubIntentSettler
{
    using SafeERC20 for IERC20;

    // ============ Constructor ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initializer ============

    /// @notice Initialize the HubIntentSettler
    /// @param owner_ The governance owner
    /// @param operator_ The solver operator (M4) / to be replaced by LZ in M5
    /// @param balanceLedger_ The BalanceLedger to credit on fill
    function initialize(address owner_, address operator_, address balanceLedger_) external initializer {
        if (owner_ == address(0)) revert ZeroAddress();
        if (operator_ == address(0)) revert ZeroAddress();
        if (balanceLedger_ == address(0)) revert ZeroAddress();

        __Ownable_init(owner_);
        __ReentrancyGuard_init();

        _operator = operator_;
        _balanceLedger = balanceLedger_;
        _pauser = owner_;

        emit OperatorUpdated(address(0), operator_);
    }

    // ============ Events ============

    /// @notice Emitted when the guardian (pauser) address is rotated
    event PauserUpdated(address indexed oldPauser, address indexed newPauser);

    // ============ Modifiers ============

    /// @notice Restricts access to the operator
    modifier onlyOperator() {
        if (msg.sender != _operator) revert Unauthorized();
        _;
    }

    /// @notice Ensures the contract is not paused
    modifier whenNotPaused() {
        if (_paused) revert ContractPaused();
        _;
    }

    /// @notice Restricts pause/unpause to the guardian (fast emergency path, no timelock)
    modifier onlyPauser() {
        if (msg.sender != _pauser) revert Unauthorized();
        _;
    }

    // ============ Operator/Solver Actions ============

    /// @inheritdoc IHubIntentSettler
    /// @custom:audit-scope OUT OF AUDIT SCOPE (hub-only launch) — dormant solver-fill path.
    function fillFor(bytes32 depositId, address user, address asset, uint256 amount, uint256 sourceChainId)
        external
        onlyOperator
        whenNotPaused
        nonReentrant
    {
        if (user == address(0)) revert ZeroAddress();
        if (asset == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        // Replay prevention: only process each depositId once
        if (_depositStatuses[depositId] != DepositStatus.NONE) {
            revert DepositAlreadyProcessed(depositId);
        }

        // Pull tokens from the solver into this contract
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        // Credit the user's available balance on the hub
        IBalanceLedger(_balanceLedger).credit(user, asset, amount);

        // Register reimbursement obligation with SettlementLedger
        ISettlementLedger(_settlementLedger).register(depositId, msg.sender, asset, amount);

        // Mark as filled
        _depositStatuses[depositId] = DepositStatus.FILLED;

        emit SolverFillRegistered(depositId, msg.sender, user, asset, amount, sourceChainId);
    }

    /// @inheritdoc IHubIntentSettler
    function markNoFill(bytes32 depositId) external onlyOperator {
        // Can only mark unfilled deposits
        if (_depositStatuses[depositId] != DepositStatus.NONE) {
            revert DepositAlreadyProcessed(depositId);
        }

        _depositStatuses[depositId] = DepositStatus.NO_FILL;

        emit DepositMarkedNoFill(depositId);
    }

    /// @inheritdoc IHubIntentSettler
    function releaseToSolver(address solver, address asset, uint256 amount) external {
        if (msg.sender != _settlementLedger) revert Unauthorized();

        IERC20(asset).safeTransfer(solver, amount);
    }

    // ============ M5 — LZ receive path ============

    /// @notice Minimal LayerZero V2 Origin struct. Matches `MockLZEndpoint.Origin`.
    struct Origin {
        uint32 srcEid;
        bytes32 sender;
        uint64 nonce;
    }

    /// @notice SPOKE_NATIVE classification constant (matches ISpokeVaultStable).
    uint8 internal constant _SPOKE_NATIVE = 2;

    /// @notice LayerZero V2 ILayerZeroReceiver hook. The endpoint calls this
    ///         on every brand-new (srcEid, sender, nonce) tuple to decide
    ///         whether a delivery path can be initialized for this receiver.
    ///         We allow only senders that match a registered trusted remote.
    /// @dev Without this method, EndpointV2._initializable returns false for
    ///      every first message from each spoke (the call would revert), and
    ///      LZ scanner reports "Not Initializable". Then no relay completes.
    function allowInitializePath(Origin calldata origin) external view returns (bool) {
        bytes32 expected = _trustedRemotes[origin.srcEid];
        return expected != bytes32(0) && origin.sender == expected;
    }

    /// @notice Receive and confirm a cross-chain deposit via LayerZero V2.
    /// @dev Called by the LZ endpoint (through `_deliver`). Verifies the message
    ///      came from a trusted spoke peer, decodes the payload, credits the
    ///      user on the BalanceLedger, and (for SPOKE_NATIVE) increments
    ///      chain liquidity on the WithdrawalRegistry.
    /// @dev LayerZero V2 ILayerZeroReceiver standard signature is
    ///      `(Origin, bytes32 guid, bytes message, address executor, bytes extraData)`.
    ///      The earlier draft used a different non-standard ordering which
    ///      caused the EndpointV2 calldata to ABI-decode incorrectly and
    ///      revert silently with empty data ("Executor transaction simulation
    ///      reverted" on LZ scanner).
    /// @custom:audit-scope OUT OF AUDIT SCOPE (hub-only launch) — dormant LayerZero receive path.
    function lzReceive(
        Origin calldata origin,
        bytes32, // guid — unused
        bytes calldata message,
        address, // executor — unused
        bytes calldata // extraData — unused
    ) external payable whenNotPaused nonReentrant {
        // Gate 1: only accept calls from the LZ endpoint.
        if (msg.sender != _lzEndpoint) revert InvalidLzEndpoint();

        // Gate 2: the source must be a registered trusted remote.
        bytes32 expectedPeer = _trustedRemotes[origin.srcEid];
        if (expectedPeer == bytes32(0) || origin.sender != expectedPeer) {
            revert UntrustedRemote(origin.srcEid, origin.sender);
        }

        // Decode the payload (same schema as SpokeDepositGateway._lzSend).
        (bytes32 depositId, address user, address asset, uint256 amount, uint8 classification, uint256 sourceChainId) =
            abi.decode(message, (bytes32, address, address, uint256, uint8, uint256));

        // Replay prevention.
        if (_depositStatuses[depositId] != DepositStatus.NONE) {
            revert DepositAlreadyProcessed(depositId);
        }

        // Credit the user's available balance on the hub.
        IBalanceLedger(_balanceLedger).credit(user, asset, amount);

        // For SPOKE_NATIVE deposits, bump chain liquidity so the
        // WithdrawalRegistry can capacity-gate outbound withdrawals.
        if (classification == _SPOKE_NATIVE && _withdrawalRegistry != address(0)) {
            IWithdrawalRegistry(_withdrawalRegistry).incrementChainLiquidity(asset, sourceChainId, amount);
        }

        _depositStatuses[depositId] = DepositStatus.CREDITED;

        emit DepositConfirmed(depositId, user, asset, amount, sourceChainId, classification);
    }

    // ============ Governance ============

    /// @notice Update the LZ endpoint pointer
    function setLzEndpoint(address endpoint) external onlyOwner {
        if (endpoint == address(0)) revert ZeroAddress();
        _lzEndpoint = endpoint;
        emit LzEndpointUpdated(endpoint);
    }

    /// @notice Register a trusted remote spoke peer
    function setTrustedRemote(uint32 eid, bytes32 peer) external onlyOwner {
        _trustedRemotes[eid] = peer;
        emit TrustedRemoteSet(eid, peer);
    }

    /// @notice Set the WithdrawalRegistry pointer
    function setWithdrawalRegistry(address registry) external onlyOwner {
        _withdrawalRegistry = registry;
        emit WithdrawalRegistryUpdated(registry);
    }

    /// @notice Update the operator address
    /// @param newOperator The new operator address
    function setOperator(address newOperator) external onlyOwner {
        if (newOperator == address(0)) revert ZeroAddress();

        address oldOperator = _operator;
        _operator = newOperator;

        emit OperatorUpdated(oldOperator, newOperator);
    }

    /// @notice Update the SettlementLedger pointer
    /// @dev Called post-deployment to resolve the circular dependency:
    ///      HubIntentSettler needs SettlementLedger for register(),
    ///      SettlementLedger needs HubIntentSettler for releaseToSolver().
    /// @param newSettlementLedger The new SettlementLedger address
    function setSettlementLedger(address newSettlementLedger) external onlyOwner {
        if (newSettlementLedger == address(0)) revert ZeroAddress();

        address oldSettlementLedger = _settlementLedger;
        _settlementLedger = newSettlementLedger;

        emit SettlementLedgerUpdated(oldSettlementLedger, newSettlementLedger);
    }

    /// @notice Pause the contract
    /// @dev Only callable by the guardian (pauser) — fast, no timelock.
    function pause() external onlyPauser {
        _paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Unpause the contract
    /// @dev Only callable by the guardian (pauser) — fast, no timelock.
    function unpause() external onlyPauser {
        _paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Rotate the guardian (pauser) address. Owner-gated (the 24h timelock in prod).
    /// @param newPauser The new guardian address
    function setPauser(address newPauser) external onlyOwner {
        if (newPauser == address(0)) revert ZeroAddress();
        address oldPauser = _pauser;
        _pauser = newPauser;
        emit PauserUpdated(oldPauser, newPauser);
    }

    // ============ Views ============

    /// @inheritdoc IHubIntentSettler
    function depositStatus(bytes32 depositId) external view returns (DepositStatus) {
        return _depositStatuses[depositId];
    }

    /// @inheritdoc IHubIntentSettler
    function balanceLedger() external view returns (address) {
        return _balanceLedger;
    }

    /// @inheritdoc IHubIntentSettler
    function settlementLedger() external view returns (address) {
        return _settlementLedger;
    }

    /// @inheritdoc IHubIntentSettler
    function operator() external view returns (address) {
        return _operator;
    }

    /// @inheritdoc IHubIntentSettler
    function paused() external view returns (bool) {
        return _paused;
    }

    /// @notice The current guardian (pauser) address
    function pauser() external view returns (address) {
        return _pauser;
    }

    /// @inheritdoc IHubIntentSettler
    function lzEndpoint() external view returns (address) {
        return _lzEndpoint;
    }

    /// @inheritdoc IHubIntentSettler
    function trustedRemote(uint32 eid) external view returns (bytes32) {
        return _trustedRemotes[eid];
    }

    /// @inheritdoc IHubIntentSettler
    function withdrawalRegistry() external view returns (address) {
        return _withdrawalRegistry;
    }
}
