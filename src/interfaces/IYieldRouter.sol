// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IYieldRouter
/// @notice Thin token-movement proxy for idle yield deployment.
/// @dev All complex logic (deployment decisions, per-user yield, rebalancing, allocation)
///      is handled OFF-CHAIN by the Centuari engine. This interface exposes only
///      token movement and on-chain verifiability functions.
interface IYieldRouter {
    // ============ Core: Token Movement ============

    /// @notice Deploy tokens from BalanceLedger to a yield adapter
    /// @param asset The token to deploy (e.g., USDC)
    /// @param amount Amount in token units
    /// @param adapter The yield adapter contract (Aave, Compound, Morpho)
    function deployToProtocol(address asset, uint256 amount, address adapter) external;

    /// @notice Recall tokens from a yield adapter back to BalanceLedger
    /// @param asset The token to recall
    /// @param amount Amount in token units
    /// @param adapter The yield adapter contract
    /// @return recalled Actual amount returned (may include yield)
    function recallFromProtocol(address asset, uint256 amount, address adapter) external returns (uint256 recalled);

    /// @notice Emergency recall ALL capital from a specific adapter. Multisig only.
    /// @param asset The token to recall
    /// @param adapter The adapter to recall from
    function emergencyRecall(address asset, address adapter) external;

    // ============ View: On-Chain Verifiability ============

    /// @notice Get actual deployed value from adapter (reads Aave aToken balance etc.)
    /// @dev Used for yield verification: actualYield = getAdapterValue() - totalDeployed
    function getAdapterValue(address asset, address adapter) external view returns (uint256);

    /// @notice Get total deployed amount for an asset across all adapters
    function getTotalDeployed(address asset) external view returns (uint256);

    /// @notice Get deployed amount for a specific adapter and asset
    function getAdapterDeployed(address adapter, address asset) external view returns (uint256);

    // ============ Adapter Management ============

    /// @notice Pause an adapter — stops deployments, allows recalls. Multisig only, 72h expiry.
    function pauseAdapter(address adapter) external;

    /// @notice Check if an adapter is currently paused
    function isAdapterPaused(address adapter) external view returns (bool);

    // ============ Events ============

    event Deployed(address indexed asset, address indexed adapter, uint256 amount);
    event Recalled(address indexed asset, address indexed adapter, uint256 requested, uint256 returned);
    event AdapterPaused(address indexed adapter, uint256 expiresAt);
    event EmergencyRecalled(address indexed asset, address indexed adapter, uint256 amount);
}
