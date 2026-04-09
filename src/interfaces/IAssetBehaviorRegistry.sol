// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IAssetBehaviorRegistry
/// @notice Root configuration for every whitelisted asset in the protocol
/// @dev All core contracts read AssetBehavior from this registry.
///      Adding any asset requires a governance vote + 48-hour timelock.
///      Zero core contract changes needed for new assets.
interface IAssetBehaviorRegistry {
    // ============ Enums ============

    /// @notice Asset classification determining yield routing behavior
    enum AssetClass {
        A, // Yield-Bearing Stable (OUSG, USDY, BUIDL)
        B, // Yield-Bearing Volatile (dividend stocks, real estate)
        C, // Non-Yielding Stable (USDC, USDT, USDe) — deployed to Aave when idle
        D  // Non-Yielding Volatile (non-dividend stocks, PAXG, commodities)
    }

    /// @notice How the asset generates native yield
    enum YieldMechanism {
        REBASING,      // Token balance grows automatically (USDY)
        SHARE_PRICE,   // NAV per token grows (OUSG, BUIDL)
        DISTRIBUTION,  // Yield arrives as separate transfer (dividend stocks)
        NONE           // No native yield (USDC, USDT, PAXG)
    }

    /// @notice How the asset is integrated cross-chain
    enum SpokeIntegrationMode {
        BRIDGE_OFT,   // Bridged via LayerZero OFT V2
        BRIDGE_CCTP,  // Bridged via Circle CCTP (USDC only)
        ATTESTATION,  // Asset stays on spoke, custody proof sent to hub
        HUB_NATIVE    // Asset exists only on Arbitrum (CBT contracts)
    }

    /// @notice How distributions (dividends) are handled for Class B assets
    enum DistributionPolicy {
        PASS_THROUGH,    // Forward to position holder immediately
        REINVEST,        // Auto-lend at current market rate
        HOLD_AS_BUFFER   // Accumulate in InsuranceReserve
    }

    // ============ Structs ============

    /// @notice Complete behavior definition for a whitelisted asset
    struct AssetBehavior {
        // Classification
        AssetClass assetClass;
        YieldMechanism yieldMechanism;
        // Yield routing
        bool deployToExternalProtocol; // true ONLY for Class C
        address preferredYieldProtocol;
        bool trackByShares;       // true for REBASING assets
        bool trackBySharePrice;   // true for SHARE_PRICE assets
        // Price and staleness
        address priceFeed;        // Chainlink price feed address
        uint256 maxStaleness;     // seconds — reject price older than this
        uint256 minPrice;         // minimum acceptable price in 18-decimal units (0 = no bound enforced)
        uint256 maxPrice;         // maximum acceptable price in 18-decimal units (0 = no bound enforced)
        // Dual-oracle verification (A1 — Loopscale $5.8M defense)
        address secondaryPriceFeed;   // secondary oracle (Redstone, Pyth) for cross-validation (0 = single oracle)
        uint256 secondaryMaxStaleness; // staleness for secondary feed (0 = use primary maxStaleness)
        // Risk parameters
        uint256 maxLTV;                // basis points (e.g., 8000 = 80%)
        uint256 liquidationThreshold;  // basis points (e.g., 8500 = 85%)
        bool hasMarketHours;
        bytes32 marketSchedule;        // exchange schedule ID
        uint256 afterHoursLTVBuffer;   // additional haircut during non-market hours (BPS)
        uint256 liquidationBonusBPS;   // liquidation bonus (500=5%, 800=8%, 1200=12%)
        // Cross-chain mode
        SpokeIntegrationMode spokeMode;
        // Compliance
        bool requiresIssuerWhitelist;
        bool hasIssuerBlocklist;
        // Distribution (Class B only)
        DistributionPolicy distributionPolicy;
        address trustedDistributionSender;
        // Caps and ceilings
        uint256 supplyCap;        // max total deposits protocol-wide (0 = unlimited)
        uint256 debtCeiling;      // max total borrows against this collateral (USD)
        uint256 minBorrowAmount;  // minimum borrow position size
        // Market role
        bool lendable;            // can be used as lending denomination
        bool collateralEligible;  // can be posted as collateral
        // Status
        bool active;              // false = deactivated (no new orders)
    }

    /// @notice Pending LTV change awaiting observation period
    struct LTVChange {
        uint256 newMaxLTV;
        uint256 newLiqThreshold;
        uint256 effectiveTimestamp;
        bool appliedToExisting;
    }

    // ============ Asset Management ============

    /// @notice Register a new asset (requires 48h timelock)
    /// @param asset The token address
    /// @param behavior The complete behavior configuration
    function addAsset(address asset, AssetBehavior calldata behavior) external;

    /// @notice Update an existing asset's behavior (requires 48h timelock)
    /// @param asset The token address
    /// @param behavior The updated behavior configuration
    function updateAsset(address asset, AssetBehavior calldata behavior) external;

    /// @notice Deactivate an asset (no timelock — conservative action)
    /// @dev New orders blocked immediately. Existing positions continue to maturity.
    /// @param asset The token address
    function deactivateAsset(address asset) external;

    /// @notice Pause a specific asset (no timelock — conservative action)
    /// @param asset The token address
    function pauseAsset(address asset) external;

    /// @notice Unpause a specific asset (requires timelock — re-enabling is riskier)
    /// @param asset The token address
    function unpauseAsset(address asset) external;

    /// @notice Apply new LTV to existing positions after 30-day observation
    /// @param asset The token address
    function applyLTVToExisting(address asset) external;

    // ============ Liquidator Whitelist ============

    /// @notice Add a liquidator to the whitelist for an asset
    function addLiquidator(address asset, address liquidator) external;

    /// @notice Remove a liquidator from the whitelist
    function removeLiquidator(address asset, address liquidator) external;

    /// @notice Check if a liquidator is approved for an asset
    function isLiquidatorApproved(address asset, address liquidator) external view returns (bool);

    // ============ View Functions ============

    /// @notice Get full behavior for an asset
    function getBehavior(address asset) external view returns (AssetBehavior memory);

    /// @notice Check if an asset is paused
    function isAssetPaused(address asset) external view returns (bool);

    /// @notice Get effective liquidation threshold (includes market hours adjustment)
    function getEffectiveLiqThreshold(address asset) external view returns (uint256);

    /// @notice Get effective max LTV (includes market hours adjustment)
    function getEffectiveMaxLTV(address asset) external view returns (uint256);

    /// @notice Get pending LTV change for an asset
    function getPendingLTVChange(address asset) external view returns (LTVChange memory);

    // ============ Events ============

    event AssetProposed(address indexed asset, AssetClass assetClass);
    event AssetAdded(address indexed asset, AssetClass assetClass);
    event AssetUpdated(address indexed asset);
    event AssetDeactivated(address indexed asset);
    event AssetPaused(address indexed asset);
    event AssetUnpaused(address indexed asset);
    event LTVChangeProposed(address indexed asset, uint256 newMaxLTV, uint256 newLiqThreshold);
    event LTVAppliedToExisting(address indexed asset, uint256 newMaxLTV);
    event LiquidatorAdded(address indexed asset, address indexed liquidator);
    event LiquidatorRemoved(address indexed asset, address indexed liquidator);

    // ============ Errors ============

    error Unauthorized();
    error ZeroAddress();
    error AssetAlreadyExists();
    error AssetNotFound();
    error AssetPausedError();
    error AssetNotActive();
    error TimelockNotExpired();
    error ObservationPeriodNotComplete();
    error InvalidLTV();
    error InvalidLiquidationThreshold();
    error MaxLiquidationBonusExceeded(); // max 2000 BPS (20%)
    error InvalidStaleness(); // M-03: maxStaleness must be > 0 when collateralEligible
    error InvalidBonus(); // M-03: liquidationBonusBPS must be > 0 when collateralEligible
    error InvalidBonusPlusThreshold(); // M-03: liquidationThreshold + bonus > 10000
}
