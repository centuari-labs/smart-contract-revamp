// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "../utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICentuariRouter} from "../interfaces/ICentuariRouter.sol";
import {ICentuariCallback} from "../interfaces/ICentuariCallback.sol";
import {CentuariRouterStorage} from "./CentuariRouterStorage.sol";

/// @title CentuariRouter
/// @notice DeFi integration entry point with intent lifecycle and ERC-4626 vault
/// @dev Security Invariant #12: onIntentFilled callable only by CentuariEndpoint.
///      Callback delivery uses 200k gas limit with try/catch.
contract CentuariRouter is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    CentuariRouterStorage,
    ICentuariRouter
{
    using SafeERC20 for IERC20;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(address owner_, address endpoint_) external initializer {
        if (owner_ == address(0) || endpoint_ == address(0)) revert ZeroAddress();
        __Ownable_init(owner_);
        __ReentrancyGuard_init();
        _endpoint = endpoint_;
    }

    modifier onlyEndpoint() {
        if (msg.sender != _endpoint) revert Unauthorized();
        _;
    }

    // ============ Intent Submission ============

    /// @inheritdoc ICentuariRouter
    function submitLendIntent(
        address asset,
        uint256 amount,
        uint256 minRateBPS,
        uint256 maturityHint,
        uint256 deadline,
        address callbackTarget
    ) external override nonReentrant returns (bytes32 intentId) {
        if (amount == 0) revert ZeroAmount();
        if (deadline <= block.timestamp + MIN_DEADLINE_OFFSET) revert InvalidDeadline();

        // Transfer tokens from caller to Router
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        intentId = keccak256(abi.encode(msg.sender, _callerNonce[msg.sender]++, block.timestamp));

        _intents[intentId] = IntentDetails({
            intentId: intentId,
            submitter: msg.sender,
            asset: asset,
            totalAmount: amount,
            filledAmount: 0,
            unfilledAmount: amount,
            rateBPS: minRateBPS,
            maturityHint: maturityHint,
            deadline: deadline,
            callbackTarget: callbackTarget == address(0) ? msg.sender : callbackTarget,
            submittedAt: block.timestamp,
            lastFilledAt: 0,
            state: IntentState.PENDING,
            isBorrow: false,
            cbtAddress: address(0),
            cbtAmount: 0,
            actualRateBPS: 0
        });

        _submitterIntents[msg.sender].push(intentId);

        emit LendIntentSubmitted(intentId, msg.sender, asset, amount, minRateBPS, maturityHint, deadline);
    }

    /// @inheritdoc ICentuariRouter
    function submitBorrowIntent(
        address borrowAsset,
        uint256 borrowAmount,
        uint256 maxRateBPS,
        uint256 maturityHint,
        uint256 deadline,
        address callbackTarget
    ) external override nonReentrant returns (bytes32 intentId) {
        if (borrowAmount == 0) revert ZeroAmount();
        if (deadline <= block.timestamp + MIN_DEADLINE_OFFSET) revert InvalidDeadline();

        intentId = keccak256(abi.encode(msg.sender, _callerNonce[msg.sender]++, block.timestamp));

        _intents[intentId] = IntentDetails({
            intentId: intentId,
            submitter: msg.sender,
            asset: borrowAsset,
            totalAmount: borrowAmount,
            filledAmount: 0,
            unfilledAmount: borrowAmount,
            rateBPS: maxRateBPS,
            maturityHint: maturityHint,
            deadline: deadline,
            callbackTarget: callbackTarget == address(0) ? msg.sender : callbackTarget,
            submittedAt: block.timestamp,
            lastFilledAt: 0,
            state: IntentState.PENDING,
            isBorrow: true,
            cbtAddress: address(0),
            cbtAmount: 0,
            actualRateBPS: 0
        });

        _submitterIntents[msg.sender].push(intentId);

        emit BorrowIntentSubmitted(intentId, msg.sender, borrowAsset, borrowAmount, maxRateBPS, maturityHint, deadline);
    }

    /// @inheritdoc ICentuariRouter
    function cancelIntent(bytes32 intentId) external override nonReentrant {
        IntentDetails storage intent = _intents[intentId];
        if (intent.submittedAt == 0) revert IntentNotFound(intentId);
        if (intent.submitter != msg.sender) revert Unauthorized();
        if (intent.state != IntentState.PENDING && intent.state != IntentState.PARTIAL) {
            revert IntentNotCancellable(intentId, intent.state);
        }

        uint256 returnAmount = intent.unfilledAmount;
        intent.state = IntentState.CANCELLED;
        intent.unfilledAmount = 0;

        if (returnAmount > 0 && !intent.isBorrow) {
            IERC20(intent.asset).safeTransfer(intent.submitter, returnAmount);
        }

        emit IntentCancelled(intentId, returnAmount);
    }

    /// @inheritdoc ICentuariRouter
    function claimUndeliveredCBT(bytes32 intentId) external override nonReentrant {
        IntentDetails storage intent = _intents[intentId];
        if (intent.submittedAt == 0) revert IntentNotFound(intentId);
        if (intent.submitter != msg.sender) revert Unauthorized();

        uint256 cbtAmount = _undeliveredCBT[intentId];
        address cbtAddr = _undeliveredCBTAddress[intentId];
        if (cbtAmount == 0) revert NoUndeliveredCBT(intentId);

        _undeliveredCBT[intentId] = 0;
        _undeliveredCBTAddress[intentId] = address(0);

        IERC20(cbtAddr).safeTransfer(msg.sender, cbtAmount);

        emit UndeliveredCBTClaimed(intentId, msg.sender, cbtAmount);
    }

    // ============ Intent Expiry (§9.2.3) ============

    /// @notice P0 FIX: Expire an intent that has passed its deadline.
    /// @dev Called by keeper bots when block.timestamp > intent.deadline.
    ///      Returns unfilled tokens to the original submitter.
    ///      Anyone can call this — it only benefits the submitter.
    /// @param intentId The intent to expire
    function expireIntent(bytes32 intentId) external nonReentrant {
        IntentDetails storage intent = _intents[intentId];
        if (intent.submittedAt == 0) revert IntentNotFound(intentId);
        if (intent.state != IntentState.PENDING && intent.state != IntentState.PARTIAL) {
            revert IntentNotCancellable(intentId, intent.state);
        }
        require(block.timestamp > intent.deadline, "CentuariRouter: not yet expired");

        uint256 returnAmount = intent.unfilledAmount;
        intent.state = IntentState.EXPIRED;
        intent.unfilledAmount = 0;

        if (returnAmount > 0 && !intent.isBorrow) {
            IERC20(intent.asset).safeTransfer(intent.submitter, returnAmount);
        }

        emit IntentExpired(intentId, returnAmount);
    }

    // ============ Fill Callback (Security Invariant #12) ============

    /// @inheritdoc ICentuariRouter
    function onIntentFilled(
        bytes32 intentId,
        address cbtAddress,
        uint256 cbtAmount,
        uint256 filledAmount,
        uint256 rateBPS
    ) external override onlyEndpoint nonReentrant {
        IntentDetails storage intent = _intents[intentId];
        if (intent.state != IntentState.PENDING && intent.state != IntentState.PARTIAL) {
            revert IntentNotFound(intentId);
        }

        intent.filledAmount += filledAmount;
        intent.unfilledAmount -= filledAmount;
        intent.cbtAddress = cbtAddress;
        intent.cbtAmount += cbtAmount;
        intent.actualRateBPS = rateBPS;
        intent.lastFilledAt = block.timestamp;
        intent.state = intent.unfilledAmount == 0 ? IntentState.FILLED : IntentState.PARTIAL;

        // P1-7 FIX: Transfer CBT FIRST, then callback. The external protocol needs
        // the tokens in hand before being notified. Chainlink VRF V2 uses the same pattern.
        address target = intent.callbackTarget;
        IERC20(cbtAddress).safeTransfer(target, cbtAmount);

        // Attempt callback (informational — CBT already delivered)
        try ICentuariCallback(target).onIntentFilled{gas: CALLBACK_GAS_LIMIT}(
            intentId, cbtAddress, cbtAmount, filledAmount, rateBPS
        ) {
            // Success — callback acknowledged
        } catch {
            // Callback failed but CBT was already transferred — log for monitoring
            emit CallbackFailed(intentId, target, cbtAmount);
        }

        emit IntentFilled(intentId, cbtAddress, cbtAmount, filledAmount, rateBPS);
    }

    // ============ ERC-4626 Vault Adapter ============
    // Reference: OpenZeppelin ERC4626 with virtual offset. Morpho MetaMorpho pattern.
    // Anti-inflation: virtual shares with 6-decimal offset + internal accounting (not balanceOf).
    // Deposit submits a lend intent at market rate to nearest maturity.
    // Withdrawal redeems matured CBT or returns pending intent tokens.

    // ERC-4626 REMOVED: deposit(), withdraw(), redeem(), totalAssets(), convertToShares(),
    // convertToAssets() deleted per P1-7. The Router is intent-only.
    // PCBTVault is the canonical ERC-20 vault for composability.
    // See: memory/architecture_audit_2026-04-03.md — ARCH-07

    // ============ View ============

    /// @inheritdoc ICentuariRouter
    function getIntentStatus(bytes32 intentId) external view override returns (IntentState, IntentDetails memory) {
        IntentDetails storage intent = _intents[intentId];
        return (intent.state, intent);
    }

    /// @inheritdoc ICentuariRouter
    function getIntentsBySubmitter(address submitter) external view override returns (bytes32[] memory) {
        return _submitterIntents[submitter];
    }

    // ============ Admin ============

    /// @notice HIGH-3 FIX: setEndpoint now requires 48h timelock.
    /// @dev The endpoint controls Invariant #12 (onIntentFilled access).
    ///      Instant change would let a compromised owner redirect intent fills.
    function proposeEndpoint(address endpoint_) external onlyOwner {
        if (endpoint_ == address(0)) revert ZeroAddress();
        _pendingEndpoint = endpoint_;
        _pendingEndpointTimelockEnd = block.timestamp + 48 hours;
    }

    function applyEndpoint() external onlyOwner {
        require(_pendingEndpoint != address(0), "CentuariRouter: no pending endpoint");
        require(block.timestamp >= _pendingEndpointTimelockEnd, "CentuariRouter: timelock active");
        _endpoint = _pendingEndpoint;
        delete _pendingEndpoint;
        delete _pendingEndpointTimelockEnd;
    }

    function cancelEndpointProposal() external onlyOwner {
        delete _pendingEndpoint;
        delete _pendingEndpointTimelockEnd;
    }

    /// @notice Propose a rate oracle change with 48h timelock.
    function proposeRateOracle(address oracle_) external onlyOwner {
        if (oracle_ == address(0)) revert ZeroAddress();
        bytes32 key = keccak256("rateOracle");
        _pendingAdminAddress[key] = oracle_;
        _pendingAdminTimelockEnd[key] = block.timestamp + ADMIN_TIMELOCK;
    }

    function applyRateOracle() external onlyOwner {
        bytes32 key = keccak256("rateOracle");
        require(_pendingAdminAddress[key] != address(0), "CentuariRouter: no pending rate oracle");
        require(block.timestamp >= _pendingAdminTimelockEnd[key], "CentuariRouter: timelock active");
        _rateOracle = _pendingAdminAddress[key];
        delete _pendingAdminAddress[key];
        delete _pendingAdminTimelockEnd[key];
    }

    function cancelRateOracleProposal() external onlyOwner {
        bytes32 key = keccak256("rateOracle");
        delete _pendingAdminAddress[key];
        delete _pendingAdminTimelockEnd[key];
    }

    /// @notice Propose an asset behavior registry change with 48h timelock.
    function proposeAssetBehaviorRegistry(address reg_) external onlyOwner {
        if (reg_ == address(0)) revert ZeroAddress();
        bytes32 key = keccak256("assetBehaviorRegistry");
        _pendingAdminAddress[key] = reg_;
        _pendingAdminTimelockEnd[key] = block.timestamp + ADMIN_TIMELOCK;
    }

    function applyAssetBehaviorRegistry() external onlyOwner {
        bytes32 key = keccak256("assetBehaviorRegistry");
        require(_pendingAdminAddress[key] != address(0), "CentuariRouter: no pending registry");
        require(block.timestamp >= _pendingAdminTimelockEnd[key], "CentuariRouter: timelock active");
        _assetBehaviorRegistry = _pendingAdminAddress[key];
        delete _pendingAdminAddress[key];
        delete _pendingAdminTimelockEnd[key];
    }

    function cancelAssetBehaviorRegistryProposal() external onlyOwner {
        bytes32 key = keccak256("assetBehaviorRegistry");
        delete _pendingAdminAddress[key];
        delete _pendingAdminTimelockEnd[key];
    }
}
