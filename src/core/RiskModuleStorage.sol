// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title RiskModuleStorage
/// @notice Storage layout for RiskModule upgradeable contract
abstract contract RiskModuleStorage {
    /// @notice BalanceLedger contract address
    address internal _balanceLedger;

    /// @notice AssetBehaviorRegistry contract address
    address internal _assetBehaviorRegistry;

    /// @notice MarketScheduleRegistry contract address
    address internal _marketScheduleRegistry;

    /// @notice Total debt outstanding against each collateral asset type (USD, 18 decimals)
    mapping(address => uint256) internal _totalDebtAgainstAsset;

    /// @notice User total debt in USD (18 decimals) — updated by CentuariEndpoint
    mapping(address => uint256) internal _userDebtUSD;

    /// @notice Authorized callers for debt recording
    mapping(address => bool) internal _authorizedCallers;

    /// @notice CRIT-2 FIX: Timelock vars for setAuthorizedCaller — moved from RiskModule.sol
    /// @dev These were declared after __gap in the implementation, which would corrupt storage on upgrade.
    address internal _pendingAuthorizedCaller;
    bool internal _pendingCallerAuthorized;
    uint256 internal _pendingCallerTimelockEnd;

    /// @notice Health factor precision (1e18 = HF 1.0)
    uint256 internal constant HF_PRECISION = 1e18;

    /// @notice BPS denominator
    uint256 internal constant BPS_DENOMINATOR = 10000;

    /// @notice Admin timelock duration
    uint256 internal constant ADMIN_TIMELOCK = 48 hours;

    /// @notice Pending admin address changes keyed by bytes32 identifier (48h timelock)
    mapping(bytes32 => address) internal _pendingAdminAddress;

    /// @notice Timelock end timestamps for pending admin address changes
    mapping(bytes32 => uint256) internal _pendingAdminTimelockEnd;

    // ============ Gap ============

    uint256[37] private __gap;
}
