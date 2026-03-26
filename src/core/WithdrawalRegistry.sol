// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "../utils/ReentrancyGuardUpgradeable.sol";

import {IWithdrawalRegistry} from "../interfaces/IWithdrawalRegistry.sol";
import {IBalanceLedger} from "../interfaces/IBalanceLedger.sol";
import {WithdrawalRegistryStorage} from "./WithdrawalRegistryStorage.sol";

/// @title WithdrawalRegistry
/// @notice Manages withdrawal requests with sequential enforcement and SLA
/// @dev Security Invariant #4: SpokePayout cannot release until recall confirmed.
///      MAX_WITHDRAWAL_QUEUE_HOURS = 4 with escalation path.
contract WithdrawalRegistry is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    WithdrawalRegistryStorage,
    IWithdrawalRegistry
{
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(address owner_, address balanceLedger_) external initializer {
        if (owner_ == address(0) || balanceLedger_ == address(0)) revert ZeroAddress();
        __Ownable_init(owner_);
        __ReentrancyGuard_init();
        _balanceLedger = balanceLedger_;
    }

    modifier onlyAuthorized() {
        if (!_authorizedCallers[msg.sender]) revert Unauthorized();
        _;
    }

    /// @inheritdoc IWithdrawalRegistry
    function MAX_WITHDRAWAL_QUEUE_HOURS() external pure override returns (uint256) {
        return _MAX_WITHDRAWAL_QUEUE_HOURS;
    }

    /// @inheritdoc IWithdrawalRegistry
    function requestWithdrawal(
        address asset,
        uint256 amount,
        uint256 targetChainId
    ) external override nonReentrant returns (bytes32 requestId) {
        if (amount == 0) revert ZeroAmount();

        requestId = keccak256(abi.encode(msg.sender, asset, amount, ++_requestCounter, block.timestamp));

        IBalanceLedger ledger = IBalanceLedger(_balanceLedger);
        uint256 available = ledger.getAvailable(msg.sender, asset);

        WithdrawalState initialState;
        if (available >= amount) {
            // Instant: debit immediately
            ledger.debit(msg.sender, asset, amount);
            initialState = WithdrawalState.PROCESSING;
        } else {
            // Queued: needs YieldRouter recall
            initialState = WithdrawalState.PENDING;
        }

        _requests[requestId] = WithdrawalRequest({
            user: msg.sender,
            asset: asset,
            amount: amount,
            requestedAt: block.timestamp,
            targetChainId: targetChainId,
            state: initialState
        });

        emit WithdrawalRequested(requestId, msg.sender, asset, amount, targetChainId);
    }

    /// @inheritdoc IWithdrawalRegistry
    function authorize(bytes32 requestId) external override onlyAuthorized {
        WithdrawalRequest storage req = _requests[requestId];
        if (req.requestedAt == 0) revert WithdrawalNotFound(requestId);
        if (req.state != WithdrawalState.PENDING && req.state != WithdrawalState.PROCESSING) {
            revert InvalidState(requestId, req.state, WithdrawalState.PROCESSING);
        }

        _authorized[requestId] = true;
        req.state = WithdrawalState.PROCESSING;

        emit WithdrawalAuthorized(requestId);
    }

    /// @inheritdoc IWithdrawalRegistry
    /// @dev CRIT-5 FIX: For same-chain (hub) withdrawals, users should call BalanceLedger.withdraw() directly.
    ///      WithdrawalRegistry is for CROSS-CHAIN withdrawals that need SpokePayout coordination.
    ///      complete() marks state but does NOT transfer tokens — the actual transfer happens via
    ///      SpokePayout.release() on the target spoke chain. For hub withdrawals, this function
    ///      is a no-op that would lock user funds if they rely on it for token receipt.
    function complete(bytes32 requestId) external override onlyAuthorized {
        WithdrawalRequest storage req = _requests[requestId];
        if (req.requestedAt == 0) revert WithdrawalNotFound(requestId);
        if (req.state != WithdrawalState.PROCESSING) {
            revert InvalidState(requestId, req.state, WithdrawalState.PROCESSING);
        }

        // CRIT-5 FIX: Revert for same-chain (targetChainId == 0 or hub chain).
        // Same-chain withdrawals must use BalanceLedger.withdraw() which performs the ERC20 transfer.
        require(req.targetChainId != 0, "WithdrawalRegistry: use BalanceLedger.withdraw() for hub chain");

        req.state = WithdrawalState.COMPLETED;
        emit WithdrawalCompleted(requestId);
    }

    /// @inheritdoc IWithdrawalRegistry
    function escalate(bytes32 requestId) external override {
        WithdrawalRequest storage req = _requests[requestId];
        if (req.requestedAt == 0) revert WithdrawalNotFound(requestId);

        uint256 elapsed = block.timestamp - req.requestedAt;
        if (elapsed < _MAX_WITHDRAWAL_QUEUE_HOURS * 1 hours) {
            revert InvalidState(requestId, req.state, WithdrawalState.ESCALATED);
        }

        req.state = WithdrawalState.ESCALATED;
        emit WithdrawalEscalated(requestId, elapsed);
    }

    // ============ View ============

    /// @inheritdoc IWithdrawalRegistry
    function getRequest(bytes32 requestId) external view override returns (WithdrawalRequest memory) {
        return _requests[requestId];
    }

    /// @inheritdoc IWithdrawalRegistry
    function isAuthorized(bytes32 requestId) external view override returns (bool) {
        return _authorized[requestId];
    }

    // ============ Admin ============

    /// @notice Propose an authorized-caller change with 48h timelock
    /// @param caller The address whose authorization is being changed
    /// @param authorized Whether to grant or revoke caller access
    function proposeAuthorizedCallerChange(address caller, bool authorized) external onlyOwner {
        if (caller == address(0)) revert ZeroAddress();
        _pendingAdminAddress[bytes32(uint256(uint160(caller)))] = caller;
        _pendingAdminBool[caller] = authorized;
        _pendingAdminTimelockEnd[bytes32(uint256(uint160(caller)))] = block.timestamp + 48 hours;
    }

    /// @notice Apply a pending authorized-caller change after the 48h timelock has elapsed
    /// @param caller The address whose authorization is being applied
    function applyAuthorizedCallerChange(address caller) external onlyOwner {
        bytes32 key = bytes32(uint256(uint160(caller)));
        require(_pendingAdminAddress[key] != address(0), "WithdrawalRegistry: no pending change");
        require(block.timestamp >= _pendingAdminTimelockEnd[key], "WithdrawalRegistry: timelock active");

        _authorizedCallers[caller] = _pendingAdminBool[caller];

        delete _pendingAdminAddress[key];
        delete _pendingAdminTimelockEnd[key];
        delete _pendingAdminBool[caller];
    }

    /// @notice Cancel a pending authorized-caller change
    /// @param caller The address whose pending change is being cancelled
    function cancelAuthorizedCallerChange(address caller) external onlyOwner {
        bytes32 key = bytes32(uint256(uint160(caller)));
        delete _pendingAdminAddress[key];
        delete _pendingAdminTimelockEnd[key];
        delete _pendingAdminBool[caller];
    }

    /// @notice Propose a YieldRouter change with 48h timelock.
    function proposeYieldRouter(address yr) external onlyOwner {
        if (yr == address(0)) revert ZeroAddress();
        bytes32 key = keccak256("yieldRouter");
        _pendingAdminAddress[key] = yr;
        _pendingAdminTimelockEnd[key] = block.timestamp + ADMIN_TIMELOCK;
    }

    function applyYieldRouter() external onlyOwner {
        bytes32 key = keccak256("yieldRouter");
        require(_pendingAdminAddress[key] != address(0), "WithdrawalRegistry: no pending yieldRouter");
        require(block.timestamp >= _pendingAdminTimelockEnd[key], "WithdrawalRegistry: timelock active");
        _yieldRouter = _pendingAdminAddress[key];
        delete _pendingAdminAddress[key];
        delete _pendingAdminTimelockEnd[key];
    }

    function cancelYieldRouterProposal() external onlyOwner {
        bytes32 key = keccak256("yieldRouter");
        delete _pendingAdminAddress[key];
        delete _pendingAdminTimelockEnd[key];
    }
}
