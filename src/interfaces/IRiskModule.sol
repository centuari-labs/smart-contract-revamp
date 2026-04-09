// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IRiskModule
/// @notice Pure computation contract for health factor, LTV enforcement, and liquidation eligibility
/// @dev All functions are view or pure. Does not hold tokens or modify state.
///      Reads from BalanceLedger, CollateralRegistry, AssetBehaviorRegistry, and price feeds.
interface IRiskModule {
    // ============ Health Factor ============

    /// @notice Compute weighted health factor across all collateral assets
    /// @dev HF = sum(collateral_i_USD * liqThreshold_i) / totalDebtUSD
    ///      Each asset weighted by its own liquidation threshold from AssetBehavior.
    /// @param user The user address
    /// @return hf18 Health factor scaled by 1e18 (1e18 = HF of 1.0)
    function getHealthFactor(address user) external view returns (uint256 hf18);

    /// @notice Get total weighted collateral value in USD for a user
    /// @dev Iterates all assets where isUsedAsCollateral[user][asset] = true
    /// @param user The user address
    /// @return weightedUSD Weighted collateral value in USD (18 decimals)
    function getWeightedCollateralUSD(address user) external view returns (uint256 weightedUSD);

    /// @notice Get weighted collateral excluding a specific asset
    /// @dev Used by BalanceLedger.setAsCollateral() safety check
    /// @param user The user address
    /// @param excludeAsset The asset to exclude from calculation
    /// @return weightedUSD Weighted collateral value excluding the asset
    function getWeightedCollateralExcluding(
        address user,
        address excludeAsset
    ) external view returns (uint256 weightedUSD);

    /// @notice Get total debt in USD for a user
    /// @param user The user address
    /// @return totalDebtUSD Total debt value in USD (18 decimals)
    function getTotalDebtUSD(address user) external view returns (uint256 totalDebtUSD);

    // ============ LTV and Thresholds ============

    /// @notice Get effective liquidation threshold for an asset (includes market hours adjustment)
    /// @param asset The asset address
    /// @return thresholdBPS Effective liquidation threshold in basis points
    function getEffectiveLiqThreshold(address asset) external view returns (uint256 thresholdBPS);

    /// @notice Get effective max LTV for an asset (includes market hours adjustment)
    /// @param asset The asset address
    /// @return ltvBPS Effective max LTV in basis points
    function getEffectiveMaxLTV(address asset) external view returns (uint256 ltvBPS);

    /// @notice Convert asset-native amount to 18-decimal USD via oracle price
    /// @dev P0-3: Uses oracle for real USD conversion. Safe for non-USD stablecoins (IDRX, XSGD).
    function toUSD18(address asset, uint256 amount) external view returns (uint256);

    // ============ Borrow Validation ============

    /// @notice Validate a proposed borrow against all risk constraints
    /// @dev Checks: collateral enabled, debt ceiling, weighted HF >= 1.0, minBorrowAmount
    /// @param borrower The borrower address
    /// @param borrowAsset The asset being borrowed
    /// @param borrowAmount The amount to borrow
    /// @param collateralAssets Array of collateral assets backing this borrow
    /// @return valid True if borrow is valid
    /// @return reason Reason string if invalid (empty if valid)
    function validateBorrow(
        address borrower,
        address borrowAsset,
        uint256 borrowAmount,
        address[] calldata collateralAssets
    ) external view returns (bool valid, string memory reason);

    // ============ Debt Tracking ============

    /// @notice Get total debt outstanding against a specific collateral asset type
    /// @param collateralAsset The collateral asset
    /// @return totalDebt Total USD debt against this collateral type
    function getTotalDebtAgainstAsset(address collateralAsset) external view returns (uint256 totalDebt);

    /// @notice Record user's total debt (called by CentuariEndpoint during settlement)
    /// @param user The borrower address
    /// @param debtUSD The debt amount in USD to add
    function recordUserDebt(address user, uint256 debtUSD) external;

    /// @notice Reduce user's total debt (called on repayment/liquidation)
    /// @param user The borrower address
    /// @param debtUSD The debt amount in USD to reduce
    function reduceUserDebt(address user, uint256 debtUSD) external;

    /// @notice Record new debt against collateral (called by CentuariEndpoint during settlement)
    /// @param collateralAsset The collateral asset
    /// @param debtUSD The debt amount in USD
    function recordDebtAgainstAsset(address collateralAsset, uint256 debtUSD) external;

    /// @notice Reduce debt against collateral (called on repayment/liquidation)
    /// @param collateralAsset The collateral asset
    /// @param debtUSD The debt amount in USD
    function reduceDebtAgainstAsset(address collateralAsset, uint256 debtUSD) external;

    // ============ Price Queries ============

    /// @notice Get current USD price for an asset from its configured price feed
    /// @param asset The asset address
    /// @return priceUSD Price in USD with 18 decimals
    /// @return updatedAt Timestamp of last price update
    function getAssetPriceUSD(address asset) external view returns (uint256 priceUSD, uint256 updatedAt);

    /// @notice Check if price feed is fresh (within maxStaleness)
    /// @param asset The asset address
    /// @return fresh True if price is within maxStaleness
    function isPriceFresh(address asset) external view returns (bool fresh);

    // ============ Events ============

    event DebtRecorded(address indexed collateralAsset, uint256 debtUSD);
    event DebtReduced(address indexed collateralAsset, uint256 debtUSD);

    // ============ Errors ============

    error Unauthorized();
    error PriceFeedStale(address asset, uint256 lastUpdated, uint256 maxStaleness);
    error InsufficientCollateral();
    error DebtCeilingExceeded(address collateralAsset, uint256 current, uint256 ceiling);
    error BelowMinBorrowAmount(address asset, uint256 amount, uint256 minimum);
    error CollateralNotEnabled(address asset);
}
