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

    /// @notice Health factor precision (1e18 = HF 1.0)
    uint256 internal constant HF_PRECISION = 1e18;

    /// @notice BPS denominator
    uint256 internal constant BPS_DENOMINATOR = 10000;

    // ============ Gap ============

    uint256[42] private __gap;
}
