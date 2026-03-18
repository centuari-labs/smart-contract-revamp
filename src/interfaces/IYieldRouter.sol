// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IYieldRouter
/// @notice Deploys idle user balances to external yield protocols and manages InsuranceReserve
/// @dev Activates immediately on deposit per AllocationConfig. Uses IYieldAdapter for each protocol.
interface IYieldRouter {
    // ============ Structs ============

    /// @notice Protocol allocation within AllocationConfig
    struct ProtocolAlloc {
        address adapter;      // IYieldAdapter contract
        uint256 targetBPS;    // target % of deployable capital
        uint256 maxBPS;       // hard cap % (cannot exceed)
    }

    /// @notice Allocation configuration per asset (mirrors Mutual Fund Vault structure)
    struct AllocationConfig {
        uint256 minCashBufferBPS;    // e.g., 1500 = 15% always liquid
        ProtocolAlloc[] protocols;   // per-protocol targets and caps
    }

    // ============ Constants ============

    /// @notice Maximum allocation to any single external protocol
    function MAX_PER_PROTOCOL_BPS() external pure returns (uint256); // 6000 = 60%

    /// @notice Minimum InsuranceReserve ratio of total deployed capital
    function MIN_RESERVE_RATIO_BPS() external pure returns (uint256); // 1000 = 10%

    /// @notice Minimum cash buffer (raw tokens, never deployed)
    function VAULT_RAW_MINIMUM_BPS() external pure returns (uint256); // 1500 = 15%

    // ============ Deployment ============

    /// @notice Deploy idle capital to external protocols per AllocationConfig
    /// @param asset The asset to deploy
    /// @param amount The amount to deploy
    /// @param adapter The target adapter
    function deploy(address asset, uint256 amount, address adapter) external;

    /// @notice Recall capital from external protocol
    /// @param user The user whose capital to recall
    /// @param asset The asset to recall
    /// @param shares The adapter shares to burn
    /// @return amount The amount returned
    function recall(address user, address asset, uint256 shares) external returns (uint256 amount);

    /// @notice Recall capital needed for an order (shortfall recall)
    /// @param user The user
    /// @param asset The asset
    /// @param shortfall The amount needed beyond cash buffer
    /// @return amount The amount recalled
    function recallForOrder(address user, address asset, uint256 shortfall) external returns (uint256 amount);

    /// @notice Recall all capital for a user/asset (router disabled)
    /// @param user The user
    /// @param asset The asset
    function recallAll(address user, address asset) external;

    /// @notice Rebalance allocations when drift exceeds threshold
    /// @param user The user
    /// @param asset The asset
    function rebalance(address user, address asset) external;

    // ============ User Controls ============

    /// @notice Enable or disable the yield router for an asset (per user)
    /// @param asset The asset
    /// @param enabled True to enable, false to disable
    function setEnabled(address asset, bool enabled) external;

    /// @notice Check if router is enabled for a user/asset
    function isEnabled(address user, address asset) external view returns (bool);

    // ============ Insurance Reserve ============

    /// @notice Verify the InsuranceReserve ratio meets minimum
    /// @return sufficient True if ratio >= MIN_RESERVE_RATIO_BPS
    function verifyReserveRatio() external view returns (bool sufficient);

    // ============ Adapter Management ============

    /// @notice Emergency pause an adapter (multisig, no timelock, 72h auto-expiry)
    /// @param adapter The adapter to pause
    function pauseAdapter(address adapter) external;

    /// @notice Check if an adapter is currently paused
    function isAdapterPaused(address adapter) external view returns (bool);

    // ============ Events ============

    event Deployed(address indexed user, address indexed asset, address indexed adapter, uint256 amount, uint256 shares);
    event Recalled(address indexed user, address indexed asset, address indexed adapter, uint256 amount, uint256 shares);
    event Rebalanced(address indexed user, address indexed asset);
    event RouterEnabledChanged(address indexed user, address indexed asset, bool enabled);
    event AdapterPaused(address indexed adapter, uint256 expiryTimestamp);
    event AdapterUnpaused(address indexed adapter);
    event AllocationConfigUpdated(address indexed asset);
    event InsuranceReserveWarning(uint256 currentRatio, uint256 minimumRatio);

    // ============ Errors ============

    error Unauthorized();
    error ZeroAddress();
    error ZeroAmount();
    error ReserveRatioViolated(uint256 currentRatio, uint256 minimum);
    error ProtocolCapExceeded(address adapter, uint256 currentBPS, uint256 maxBPS);
    error AdapterPausedError(address adapter);
    error RecallFailed(address adapter, address asset);
    error RouterDisabled(address user, address asset);
}
