// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IYieldAdapter
/// @notice Interface for external protocol adapters used by YieldRouter
/// @dev Each approved external protocol (Aave, Compound, Morpho) is wrapped in an IYieldAdapter.
///      SECURITY: All functions MUST use nonReentrant. Adapters MUST track internal balances
///      (not rely on balanceOf) to prevent donation/inflation attacks on share pricing.
interface IYieldAdapter {
    /// @notice Deploy asset to external protocol
    /// @dev Called at: user deposit if router enabled, rebalance when allocation drifts
    /// @param asset The asset to deploy
    /// @param amount The amount to deploy
    /// @return shares Shares representing the position
    function deploy(address asset, uint256 amount) external returns (uint256 shares);

    /// @notice Recall deployed capital — burns shares, returns asset + accrued yield
    /// @dev Called at: order placement (shortfall), withdrawal, router disabled, rebalance trim
    /// @param asset The asset to recall
    /// @param shares The shares to burn
    /// @return amount The amount of asset returned (including yield)
    function recall(address asset, uint256 shares) external returns (uint256 amount);

    /// @notice Get current USD value of shares position including accrued yield
    /// @param asset The asset
    /// @param shares The shares held
    /// @return usdValue Current USD value (18 decimals)
    function getDeployedValue(address asset, uint256 shares) external view returns (uint256 usdValue);

    /// @notice Get current annualized yield rate for an asset
    /// @param asset The asset
    /// @return bps Annual yield in basis points
    function getAPY(address asset) external view returns (uint256 bps);

    /// @notice Check if protocol is operational and accepting deposits
    /// @param asset The asset to check
    /// @return True if available
    function isAvailable(address asset) external view returns (bool);

    /// @notice Check if the given shares can be recalled immediately
    /// @dev False if protocol has withdrawal queue or insufficient liquidity
    /// @param asset The asset
    /// @param shares The shares to check
    /// @return True if recall would succeed
    function canRecall(address asset, uint256 shares) external view returns (bool);
}
