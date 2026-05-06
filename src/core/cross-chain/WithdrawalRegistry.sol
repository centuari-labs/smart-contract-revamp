// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {IWithdrawalRegistry} from "../../interfaces/cross-chain/IWithdrawalRegistry.sol";
import {IBalanceLedger} from "../../interfaces/IBalanceLedger.sol";
import {IRiskModule} from "../../interfaces/IRiskModule.sol";
import {IHubDepositor} from "../../interfaces/cross-chain/IHubDepositor.sol";
import {WithdrawalRegistryStorage} from "./WithdrawalRegistryStorage.sol";
import {ReentrancyGuardUpgradeable} from "../../utils/ReentrancyGuardUpgradeable.sol";

/// @notice Minimal LZ V2 endpoint surface for payout dispatch.
interface ILzEndpointSend {
    struct MessagingParams {
        uint32 dstEid;
        bytes32 receiver;
        bytes message;
        bytes options;
        bool payInLzToken;
    }

    struct MessagingFee {
        uint256 nativeFee;
        uint256 lzTokenFee;
    }

    struct MessagingReceipt {
        bytes32 guid;
        uint64 nonce;
        MessagingFee fee;
    }

    function send(MessagingParams calldata params, address refundAddress)
        external
        payable
        returns (MessagingReceipt memory);
}

/// @title WithdrawalRegistry
/// @notice Manages the withdrawal state machine with a uniform on-chain HF gate.
/// @dev Every withdrawal — whether initiated by an app user (via backend), a
///      direct-contract caller, or a Phase 6 integrator — passes through
///      `requestWithdrawal`, which calls `IRiskModule.canWithdraw` as its FIRST
///      action. This is the single enforcement point that closes the collateral
///      flag loophole.
///
///      State machine: PENDING → PROCESSING → COMPLETED (or FAILED terminal).
///      Hub-native withdrawals (targetChainId == block.chainid) shortcut
///      directly from PENDING to COMPLETED via `HubDepositor.payoutDirect`.
///
///      Must be registered as a BalanceLedger authorized writer (for debit on
///      request and credit on refund).
contract WithdrawalRegistry is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    WithdrawalRegistryStorage,
    IWithdrawalRegistry
{
    // ============ Constructor ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initializer ============

    /// @notice Initialize the WithdrawalRegistry
    /// @param owner_ The governance owner
    /// @param operator_ The backend operator (settlement key)
    /// @param balanceLedger_ The BalanceLedger to debit/credit
    /// @param riskModule_ The RiskModule for HF checks
    /// @param hubDepositor_ The HubDepositor for hub-native payouts
    function initialize(
        address owner_,
        address operator_,
        address balanceLedger_,
        address riskModule_,
        address hubDepositor_
    ) external initializer {
        if (owner_ == address(0)) revert ZeroAddress();
        if (operator_ == address(0)) revert ZeroAddress();
        if (balanceLedger_ == address(0)) revert ZeroAddress();
        if (riskModule_ == address(0)) revert ZeroAddress();
        if (hubDepositor_ == address(0)) revert ZeroAddress();

        __Ownable_init(owner_);
        __ReentrancyGuard_init();

        _operator = operator_;
        _balanceLedger = balanceLedger_;
        _riskModule = riskModule_;
        _hubDepositor = hubDepositor_;
        _paused = false;

        emit OperatorUpdated(address(0), operator_);
        emit RiskModuleUpdated(address(0), riskModule_);
        emit HubDepositorUpdated(address(0), hubDepositor_);
    }

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

    // ============ User Actions ============

    /// @inheritdoc IWithdrawalRegistry
    function requestWithdrawal(address asset, uint256 amount, uint256 targetChainId)
        external
        whenNotPaused
        nonReentrant
        returns (bytes32 requestId)
    {
        if (asset == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        // ---- HF GATE (first action) ----
        // This is the single uniform check that applies to every caller.
        // Phase 1 stub: rejects if asset is flagged as collateral.
        // Phase 2 real: rejects if post-withdrawal HF < 1.
        if (!IRiskModule(_riskModule).canWithdraw(msg.sender, asset, amount)) {
            revert WithdrawalBlockedByHF();
        }

        // Debit the user's available balance (reverts with
        // InsufficientBalance if not enough)
        IBalanceLedger(_balanceLedger).debit(msg.sender, asset, amount);

        // ---- CHAIN-LIQUIDITY GATE (M5) ----
        // For SPOKE_NATIVE routes, enforce that sufficient physical liquidity
        // exists on the target chain. Decrement atomically with the debit.
        if (_isSpokeNativeRoute[asset][targetChainId]) {
            uint256 available = _chainLiquidity[asset][targetChainId];
            if (available < amount) {
                revert InsufficientChainLiquidity(asset, targetChainId, available, amount);
            }
            _chainLiquidity[asset][targetChainId] = available - amount;

            emit ChainLiquidityDecremented(asset, targetChainId, amount, available - amount);
        }

        // Generate unique requestId
        requestId = keccak256(abi.encode(msg.sender, asset, amount, targetChainId, _requestCounter++));

        // Store the request
        _requests[requestId] = WithdrawalRequest({
            user: msg.sender,
            asset: asset,
            amount: amount,
            targetChainId: targetChainId,
            status: WithdrawalStatus.PENDING,
            createdAt: uint64(block.timestamp),
            updatedAt: uint64(block.timestamp)
        });

        emit WithdrawalRequested(requestId, msg.sender, asset, amount, targetChainId);
    }

    // ============ Operator Actions ============

    /// @inheritdoc IWithdrawalRegistry
    function authorize(bytes32 requestId) external payable onlyOperator whenNotPaused nonReentrant {
        WithdrawalRequest storage request = _requests[requestId];
        if (request.user == address(0)) revert InvalidRequestId();

        if (request.status != WithdrawalStatus.PENDING) {
            revert InvalidStatusTransition(request.status, WithdrawalStatus.PROCESSING);
        }

        request.updatedAt = uint64(block.timestamp);

        if (request.targetChainId == block.chainid) {
            // Hub-native shortcut: release tokens directly and complete
            request.status = WithdrawalStatus.COMPLETED;

            IHubDepositor(_hubDepositor).payoutDirect(request.user, request.asset, request.amount);

            emit WithdrawalAuthorized(requestId);
            emit WithdrawalCompleted(requestId);
        } else {
            // Cross-chain: dispatch payout via LayerZero to SpokePayout.
            if (_payoutEndpoint == address(0)) revert PayoutEndpointNotSet();
            uint32 spokeEid = _spokeEidByChainId[request.targetChainId];
            if (spokeEid == 0) revert SpokeEidNotMapped(request.targetChainId);
            bytes32 peer = _payoutPeers[spokeEid];
            if (peer == bytes32(0)) revert PayoutPeerNotSet(spokeEid);

            // Determine classification: check if this route is spoke-native.
            uint8 classification = _isSpokeNativeRoute[request.asset][request.targetChainId]
                ? uint8(2) // SPOKE_NATIVE
                : uint8(1); // BRIDGED

            bytes memory payload = abi.encode(requestId, request.user, request.asset, request.amount, classification);

            ILzEndpointSend.MessagingParams memory params = ILzEndpointSend.MessagingParams({
                dstEid: spokeEid,
                receiver: peer,
                message: payload,
                options: bytes(""),
                payInLzToken: false
            });

            ILzEndpointSend.MessagingReceipt memory receipt =
                ILzEndpointSend(_payoutEndpoint).send{value: msg.value}(params, msg.sender);

            request.status = WithdrawalStatus.PROCESSING;

            emit WithdrawalAuthorized(requestId);
            emit PayoutDispatched(requestId, request.targetChainId, receipt.guid);
        }
    }

    /// @inheritdoc IWithdrawalRegistry
    function markCompleted(bytes32 requestId) external onlyOperator nonReentrant {
        WithdrawalRequest storage request = _requests[requestId];
        if (request.user == address(0)) revert InvalidRequestId();

        if (request.status != WithdrawalStatus.PROCESSING) {
            revert InvalidStatusTransition(request.status, WithdrawalStatus.COMPLETED);
        }

        request.status = WithdrawalStatus.COMPLETED;
        request.updatedAt = uint64(block.timestamp);

        emit WithdrawalCompleted(requestId);
    }

    /// @inheritdoc IWithdrawalRegistry
    function markFailed(bytes32 requestId) external onlyOperator nonReentrant {
        WithdrawalRequest storage request = _requests[requestId];
        if (request.user == address(0)) revert InvalidRequestId();

        // Can fail from PENDING or PROCESSING
        if (request.status != WithdrawalStatus.PENDING && request.status != WithdrawalStatus.PROCESSING) {
            revert InvalidStatusTransition(request.status, WithdrawalStatus.FAILED);
        }

        request.status = WithdrawalStatus.FAILED;
        request.updatedAt = uint64(block.timestamp);

        // Refund the user's available balance
        IBalanceLedger(_balanceLedger).credit(request.user, request.asset, request.amount);

        emit WithdrawalFailed(requestId);
    }

    // ============ M5 — Chain-liquidity management ============

    /// @inheritdoc IWithdrawalRegistry
    function incrementChainLiquidity(address asset, uint256 chainId, uint256 amount) external {
        if (msg.sender != _hubIntentSettler) revert Unauthorized();
        if (amount == 0) revert ZeroAmount();

        _chainLiquidity[asset][chainId] += amount;

        emit ChainLiquidityIncremented(asset, chainId, amount, _chainLiquidity[asset][chainId]);
    }

    // ============ Governance ============

    /// @inheritdoc IWithdrawalRegistry
    function setPayoutEndpoint(address endpoint_) external onlyOwner {
        _payoutEndpoint = endpoint_;
        emit PayoutEndpointUpdated(endpoint_);
    }

    /// @inheritdoc IWithdrawalRegistry
    function setPayoutPeer(uint32 eid, bytes32 peer) external onlyOwner {
        _payoutPeers[eid] = peer;
        emit PayoutPeerSet(eid, peer);
    }

    /// @inheritdoc IWithdrawalRegistry
    function setSpokeEid(uint256 chainId, uint32 eid) external onlyOwner {
        _spokeEidByChainId[chainId] = eid;
        emit SpokeEidSet(chainId, eid);
    }

    /// @inheritdoc IWithdrawalRegistry
    function setHubIntentSettler(address settler) external onlyOwner {
        _hubIntentSettler = settler;
        emit HubIntentSettlerUpdated(settler);
    }

    /// @inheritdoc IWithdrawalRegistry
    function setSpokeNativeRoute(address asset, uint256 chainId, bool enabled) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        _isSpokeNativeRoute[asset][chainId] = enabled;
        emit SpokeNativeRouteSet(asset, chainId, enabled);
    }

    /// @notice Update the operator address
    /// @param newOperator The new operator address
    function setOperator(address newOperator) external onlyOwner {
        if (newOperator == address(0)) revert ZeroAddress();

        address oldOperator = _operator;
        _operator = newOperator;

        emit OperatorUpdated(oldOperator, newOperator);
    }

    /// @notice Update the RiskModule pointer (Phase 2 swap point)
    /// @param newRiskModule The new RiskModule address
    function setRiskModule(address newRiskModule) external onlyOwner {
        if (newRiskModule == address(0)) revert ZeroAddress();

        address oldRiskModule = _riskModule;
        _riskModule = newRiskModule;

        emit RiskModuleUpdated(oldRiskModule, newRiskModule);
    }

    /// @notice Update the HubDepositor pointer
    /// @param newHubDepositor The new HubDepositor address
    function setHubDepositor(address newHubDepositor) external onlyOwner {
        if (newHubDepositor == address(0)) revert ZeroAddress();

        address oldHubDepositor = _hubDepositor;
        _hubDepositor = newHubDepositor;

        emit HubDepositorUpdated(oldHubDepositor, newHubDepositor);
    }

    /// @notice Pause the contract
    function pause() external onlyOwner {
        _paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Unpause the contract
    function unpause() external onlyOwner {
        _paused = false;
        emit Unpaused(msg.sender);
    }

    // ============ Views ============

    /// @inheritdoc IWithdrawalRegistry
    function getRequest(bytes32 requestId) external view returns (WithdrawalRequest memory) {
        return _requests[requestId];
    }

    /// @inheritdoc IWithdrawalRegistry
    function balanceLedger() external view returns (address) {
        return _balanceLedger;
    }

    /// @inheritdoc IWithdrawalRegistry
    function riskModule() external view returns (address) {
        return _riskModule;
    }

    /// @inheritdoc IWithdrawalRegistry
    function hubDepositor() external view returns (address) {
        return _hubDepositor;
    }

    /// @inheritdoc IWithdrawalRegistry
    function operator() external view returns (address) {
        return _operator;
    }

    /// @inheritdoc IWithdrawalRegistry
    function paused() external view returns (bool) {
        return _paused;
    }

    /// @inheritdoc IWithdrawalRegistry
    function chainLiquidity(address asset, uint256 chainId) external view returns (uint256) {
        return _chainLiquidity[asset][chainId];
    }

    /// @inheritdoc IWithdrawalRegistry
    function isSpokeNativeRoute(address asset, uint256 chainId) external view returns (bool) {
        return _isSpokeNativeRoute[asset][chainId];
    }

    /// @inheritdoc IWithdrawalRegistry
    function hubIntentSettler() external view returns (address) {
        return _hubIntentSettler;
    }

    /// @inheritdoc IWithdrawalRegistry
    function payoutEndpoint() external view returns (address) {
        return _payoutEndpoint;
    }

    /// @inheritdoc IWithdrawalRegistry
    function payoutPeer(uint32 eid) external view returns (bytes32) {
        return _payoutPeers[eid];
    }

    /// @inheritdoc IWithdrawalRegistry
    function spokeEidByChainId(uint256 chainId) external view returns (uint32) {
        return _spokeEidByChainId[chainId];
    }
}
