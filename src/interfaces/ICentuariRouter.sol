// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ICentuariRouter
/// @notice DeFi integration entry point for external protocols
/// @dev Implements intent lifecycle (6 states) and ERC-4626 vault adapter.
///      External protocols deposit tokens here, specify parameters, and receive CBT on fill.
interface ICentuariRouter {
    // ============ Enums ============

    enum IntentState {
        PENDING,
        PARTIAL,
        FILLED,
        CANCELLED,
        EXPIRED,
        CALLBACK_FAILED
    }

    // ============ Structs ============

    struct IntentDetails {
        bytes32 intentId;
        address submitter;
        address asset;
        uint256 totalAmount;
        uint256 filledAmount;
        uint256 unfilledAmount;
        uint256 rateBPS;         // minRate (lend) or maxRate (borrow)
        uint256 maturityHint;
        uint256 deadline;
        address callbackTarget;
        uint256 submittedAt;
        uint256 lastFilledAt;
        IntentState state;
        bool isBorrow;
        address cbtAddress;
        uint256 cbtAmount;
        uint256 actualRateBPS;
    }

    // ============ Intent Submission ============

    /// @notice Submit a lend intent — deposit tokens and specify lending parameters
    /// @param asset The lending asset (USDC, USDT, etc.)
    /// @param amount The amount to lend
    /// @param minRateBPS Minimum acceptable rate in BPS (0 = market order)
    /// @param maturityHint Preferred maturity timestamp (0 = nearest)
    /// @param deadline Unix timestamp — auto-expire if unfilled
    /// @param callbackTarget Contract to notify on fill (address(0) = caller)
    /// @return intentId The unique intent identifier
    function submitLendIntent(
        address asset,
        uint256 amount,
        uint256 minRateBPS,
        uint256 maturityHint,
        uint256 deadline,
        address callbackTarget
    ) external returns (bytes32 intentId);

    /// @notice Submit a borrow intent
    /// @param borrowAsset The asset to borrow
    /// @param borrowAmount The amount to borrow
    /// @param maxRateBPS Maximum rate borrower accepts in BPS
    /// @param maturityHint Preferred maturity timestamp
    /// @param deadline Unix timestamp for expiry
    /// @param callbackTarget Contract to notify on fill
    /// @return intentId The unique intent identifier
    function submitBorrowIntent(
        address borrowAsset,
        uint256 borrowAmount,
        uint256 maxRateBPS,
        uint256 maturityHint,
        uint256 deadline,
        address callbackTarget
    ) external returns (bytes32 intentId);

    /// @notice Cancel an unfilled or partially filled intent
    /// @dev Returns unfilled tokens to original submitter immediately
    /// @param intentId The intent to cancel
    function cancelIntent(bytes32 intentId) external;

    /// @notice Claim CBT from a filled intent where callback failed
    /// @param intentId The intent with undelivered CBT
    function claimUndeliveredCBT(bytes32 intentId) external;

    // ============ Fill Callback (CentuariEndpoint only) ============

    /// @notice Called by CentuariEndpoint during settlement after intent is matched
    /// @dev Transfers CBT to callbackTarget. If callback reverts, holds for manual claim.
    ///      Gas limit: 200,000 on callback. Security Invariant #12: onlyEndpoint.
    /// @param intentId The matched intent
    /// @param cbtAddress The CBT contract address
    /// @param cbtAmount The CBT amount minted
    /// @param filledAmount The matched amount (may be partial)
    /// @param rateBPS The actual matched rate
    function onIntentFilled(
        bytes32 intentId,
        address cbtAddress,
        uint256 cbtAmount,
        uint256 filledAmount,
        uint256 rateBPS
    ) external;

    // ============ ERC-4626 Vault Adapter ============

    /// @notice Deposit USDC, get vault shares (submits lend intent at market rate)
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    /// @notice Withdraw underlying by burning vault shares
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);

    /// @notice Redeem vault shares for underlying
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);

    /// @notice Total assets managed by the vault
    function totalAssets() external view returns (uint256);

    /// @notice Convert assets to shares
    function convertToShares(uint256 assets) external view returns (uint256);

    /// @notice Convert shares to assets
    function convertToAssets(uint256 shares) external view returns (uint256);

    // ============ View Functions ============

    function getIntentStatus(bytes32 intentId) external view returns (IntentState state, IntentDetails memory details);
    function getIntentsBySubmitter(address submitter) external view returns (bytes32[] memory intentIds);

    // ============ Events ============

    event LendIntentSubmitted(bytes32 indexed intentId, address indexed submitter, address indexed asset, uint256 amount, uint256 minRateBPS, uint256 maturityHint, uint256 deadline);
    event BorrowIntentSubmitted(bytes32 indexed intentId, address indexed submitter, address indexed asset, uint256 amount, uint256 maxRateBPS, uint256 maturityHint, uint256 deadline);
    event IntentFilled(bytes32 indexed intentId, address indexed cbtAddress, uint256 cbtAmount, uint256 filledAmount, uint256 rateBPS);
    event IntentCancelled(bytes32 indexed intentId, uint256 returnedAmount);
    event IntentExpired(bytes32 indexed intentId, uint256 returnedAmount);
    event CallbackFailed(bytes32 indexed intentId, address indexed target, uint256 cbtAmount);
    event UndeliveredCBTClaimed(bytes32 indexed intentId, address indexed claimer, uint256 cbtAmount);

    // ============ Errors ============

    error Unauthorized();
    error ZeroAddress();
    error ZeroAmount();
    error InvalidDeadline();
    error RateOutOfBounds();
    error IntentNotFound(bytes32 intentId);
    error IntentNotCancellable(bytes32 intentId, IntentState currentState);
    error NoUndeliveredCBT(bytes32 intentId);
    error AssetNotLendable(address asset);
    error AssetPaused(address asset);
    error OracleStale();
}
