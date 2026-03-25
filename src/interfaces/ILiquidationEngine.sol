// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ILiquidationEngine
/// @notice Executes liquidations for undercollateralized positions
/// @dev Supports hub-native and cross-chain RWA collateral. Enforces grace periods on-chain.
interface ILiquidationEngine {
    // ============ Structs ============

    /// @notice Grace period state for a borrow position
    struct GracePeriodState {
        uint256 startTimestamp;
        uint256 deadlineTimestamp;
        uint8 reason;           // 0=HF_TOO_LOW, 1=RATE_CEILING, 2=NO_LENDERS, 3=AUTO_OFF, 4=MAX_REFINANCES
        uint256 penaltyRateBPS; // 2x CentuariRateOracle VWAP
        uint256 accruedPenalty;
    }

    // ============ Constants ============

    /// @notice Maximum grace period duration in hours
    /// @return 24 hours
    function MAX_GRACE_PERIOD_HOURS() external pure returns (uint256);

    // ============ Liquidation ============

    /// @notice Execute a liquidation
    /// @dev Checks: HF < 1.0, debt coverage <= 50%, collateral active, oracle fresh, grace period expired
    /// @param borrower The borrower to liquidate
    /// @param debtAsset The debt asset to repay
    /// @param debtToCover Amount of debt to repay (up to 50% of total)
    /// @param collateralAsset Which collateral the liquidator wants to claim
    function liquidate(
        address borrower,
        address debtAsset,
        uint256 debtToCover,
        address collateralAsset
    ) external;

    /// @notice Retry a failed cross-chain liquidation
    /// @param requestId The original liquidation request ID
    function retryLiquidation(bytes32 requestId) external;

    // ============ Grace Period ============

    /// @notice Set grace period for a borrow position (called by CentuariEndpoint)
    /// @param positionId The borrow position ID
    /// @param gracePeriodHours Duration in hours (max 24)
    /// @param reason The reason code
    /// @dev 1C FIX: penaltyRateBPS parameter added. Off-chain engine computes 2x VWAP.
    function setGracePeriod(
        bytes32 positionId,
        uint256 gracePeriodHours,
        uint8 reason,
        uint256 penaltyRateBPS
    ) external;

    /// @notice Flag a position as liquidatable after grace period expiry
    /// @param positionId The borrow position ID
    function flagForLiquidation(bytes32 positionId) external;

    /// @notice Get grace period state for a position
    function getGracePeriod(bytes32 positionId) external view returns (GracePeriodState memory);

    /// @notice Check if a position is in grace period
    function isInGracePeriod(bytes32 positionId) external view returns (bool);

    /// @notice Check if a position is liquidatable
    function isLiquidatable(bytes32 positionId) external view returns (bool);

    // ============ Events ============

    event LiquidationExecuted(
        address indexed borrower,
        address indexed liquidator,
        address indexed collateralAsset,
        uint256 collateralSeized,
        uint256 debtRepaid,
        uint256 bonusBPS
    );

    event CrossChainLiquidationInitiated(
        bytes32 indexed requestId,
        address indexed borrower,
        address indexed collateralAsset,
        uint256 sourceChainId
    );

    event GracePeriodSet(
        address indexed borrower,
        bytes32 indexed positionId,
        uint256 deadlineTimestamp,
        uint8 reason
    );

    event PositionFlaggedLiquidatable(bytes32 indexed positionId);

    // ============ Errors ============

    error Unauthorized();
    error PositionHealthy(uint256 healthFactor);
    error ExceedsMaxDebtCoverage(uint256 debtToCover, uint256 maxAllowed);
    error CollateralNotActive();
    error CollateralNotEnabled();
    error PriceFeedStale();
    error GracePeriodNotExpired(uint256 deadline, uint256 currentTime);
    error ExceedsMaxGracePeriod(uint256 requested, uint256 maximum);
    error LiquidatorNotApproved(address liquidator, address asset);
    error InsufficientCollateral();
}
