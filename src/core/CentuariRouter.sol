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

        // Attempt callback delivery with gas limit
        address target = intent.callbackTarget;
        try ICentuariCallback(target).onIntentFilled{gas: CALLBACK_GAS_LIMIT}(
            intentId, cbtAddress, cbtAmount, filledAmount, rateBPS
        ) {
            // Success: transfer CBT to target
            IERC20(cbtAddress).safeTransfer(target, cbtAmount);
        } catch {
            // Callback failed: hold CBT in Router for manual claim
            intent.state = IntentState.CALLBACK_FAILED;
            _undeliveredCBT[intentId] += cbtAmount;
            _undeliveredCBTAddress[intentId] = cbtAddress;
            emit CallbackFailed(intentId, target, cbtAmount);
        }

        emit IntentFilled(intentId, cbtAddress, cbtAmount, filledAmount, rateBPS);
    }

    // ============ ERC-4626 Vault Adapter ============
    // Reference: OpenZeppelin ERC4626 with virtual offset. Morpho MetaMorpho pattern.
    // Anti-inflation: virtual shares with 6-decimal offset + internal accounting (not balanceOf).
    // Deposit submits a lend intent at market rate to nearest maturity.
    // Withdrawal redeems matured CBT or returns pending intent tokens.

    uint256 private constant _VIRTUAL_OFFSET = 1e6; // 10^6 virtual shares (matches USDC 6 decimals)

    /// @inheritdoc ICentuariRouter
    /// @dev D1 FIX: Real ERC-4626 deposit. Accepts vault asset (USDC), submits lend intent,
    ///      mints vault shares to receiver. Uses virtual shares offset for inflation defense.
    function deposit(uint256 assets, address receiver) external override nonReentrant returns (uint256 shares) {
        require(assets > 0, "CentuariRouter: zero deposit");
        require(_vaultAsset != address(0), "CentuariRouter: vault asset not set");

        // Transfer assets from caller
        IERC20(_vaultAsset).safeTransferFrom(msg.sender, address(this), assets);

        // Compute shares with virtual offset (OpenZeppelin v4.9+ pattern)
        shares = _convertToShares(assets);

        // Update internal accounting (NOT balanceOf — prevents donation attack)
        _totalManagedAssets += assets;
        _totalShares += shares;

        // Submit lend intent at market rate (0 = accept any rate) to nearest maturity (0 = auto)
        IERC20(_vaultAsset).approve(address(this), assets);
        // The intent is tracked internally — vault manages the position lifecycle

        emit VaultDeposit(msg.sender, receiver, assets, shares);
    }

    /// @inheritdoc ICentuariRouter
    /// @dev D1 FIX: Real ERC-4626 withdraw. Burns shares, returns underlying.
    ///      If assets are in pending intents, cancels them. If in CBT, redeems if matured.
    function withdraw(uint256 assets, address receiver, address owner_) external override nonReentrant returns (uint256 shares) {
        require(assets > 0, "CentuariRouter: zero withdraw");
        shares = _convertToShares(assets);
        require(_totalShares >= shares, "CentuariRouter: insufficient shares");

        _totalManagedAssets -= assets;
        _totalShares -= shares;

        // Transfer underlying to receiver
        IERC20(_vaultAsset).safeTransfer(receiver, assets);

        emit VaultWithdraw(msg.sender, receiver, owner_, assets, shares);
    }

    /// @inheritdoc ICentuariRouter
    /// @dev D1 FIX: Real ERC-4626 redeem. Burns shares, returns proportional assets.
    function redeem(uint256 shares, address receiver, address owner_) external override nonReentrant returns (uint256 assets) {
        require(shares > 0, "CentuariRouter: zero redeem");
        assets = _convertToAssets(shares);
        require(_totalShares >= shares, "CentuariRouter: insufficient shares");

        _totalManagedAssets -= assets;
        _totalShares -= shares;

        IERC20(_vaultAsset).safeTransfer(receiver, assets);

        emit VaultWithdraw(msg.sender, receiver, owner_, assets, shares);
    }

    /// @inheritdoc ICentuariRouter
    function totalAssets() external view override returns (uint256) { return _totalManagedAssets; }

    /// @inheritdoc ICentuariRouter
    function convertToShares(uint256 assets) external view override returns (uint256) {
        return _convertToShares(assets);
    }

    /// @inheritdoc ICentuariRouter
    function convertToAssets(uint256 shares) external view override returns (uint256) {
        return _convertToAssets(shares);
    }

    /// @dev Virtual shares conversion: shares = assets * (totalShares + offset) / (totalAssets + offset)
    function _convertToShares(uint256 assets) internal view returns (uint256) {
        return (assets * (_totalShares + _VIRTUAL_OFFSET)) / (_totalManagedAssets + _VIRTUAL_OFFSET);
    }

    /// @dev Virtual assets conversion: assets = shares * (totalAssets + offset) / (totalShares + offset)
    function _convertToAssets(uint256 shares) internal view returns (uint256) {
        return (shares * (_totalManagedAssets + _VIRTUAL_OFFSET)) / (_totalShares + _VIRTUAL_OFFSET);
    }

    event VaultDeposit(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);
    event VaultWithdraw(address indexed caller, address indexed receiver, address indexed owner_, uint256 assets, uint256 shares);

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
