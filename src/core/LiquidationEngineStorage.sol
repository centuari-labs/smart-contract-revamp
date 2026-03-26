// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ILiquidationEngine} from "../interfaces/ILiquidationEngine.sol";

/// @title LiquidationEngineStorage
/// @notice Storage layout for LiquidationEngine upgradeable contract
abstract contract LiquidationEngineStorage {
    /// @notice Grace period states per position
    mapping(bytes32 => ILiquidationEngine.GracePeriodState) internal _gracePeriods;

    /// @notice Positions flagged as liquidatable (grace period expired)
    mapping(bytes32 => bool) internal _liquidatable;

    /// @notice BalanceLedger contract
    address internal _balanceLedger;

    /// @notice RiskModule contract
    address internal _riskModule;

    /// @notice AssetBehaviorRegistry contract
    address internal _assetBehaviorRegistry;

    /// @notice CentuariRateOracle contract (for penalty interest VWAP)
    address internal _rateOracle;

    /// @notice LayerZero endpoint for cross-chain liquidation commands
    address internal _layerZeroEndpoint;

    /// @notice Authorized callers (CentuariEndpoint, keeper bots)
    mapping(address => bool) internal _authorizedCallers;

    /// @notice Maximum grace period in hours
    uint256 internal constant _MAX_GRACE_PERIOD_HOURS = 24;

    /// @notice Health factor precision
    uint256 internal constant HF_PRECISION = 1e18;

    /// @notice BPS denominator
    uint256 internal constant BPS_DENOMINATOR = 10000;

    /// @notice Maximum debt coverage per liquidation (50%)
    uint256 internal constant MAX_DEBT_COVERAGE_BPS = 5000;

    /// @notice Pending admin address changes keyed by bytes32 identifier (48h timelock)
    mapping(bytes32 => address) internal _pendingAdminAddress;

    /// @notice Timelock end timestamps for pending admin address changes
    mapping(bytes32 => uint256) internal _pendingAdminTimelockEnd;

    /// @notice Pending authorized-caller bool keyed by caller address (48h timelock)
    mapping(address => bool) internal _pendingAdminBool;

    // ============ Gap ============

    uint256[37] private __gap;
}
