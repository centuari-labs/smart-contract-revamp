// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title LiquidationEngineStorage
/// @notice Storage layout for the upgradeable LiquidationEngine.
/// @dev IMPORTANT: only append new storage variables to the end. Never reorder,
///      remove, or change types of existing variables. Maintain the __gap.
abstract contract LiquidationEngineStorage {
    // ============ Dependencies ============

    /// @notice Centuari (debt source + liquidationRepay hook).
    address internal _centuari;

    /// @notice BalanceLedger (collateral balances + seizure writes).
    address internal _balanceLedger;

    /// @notice RiskModule (HF liquidation trigger via isLiquidatable).
    address internal _riskModule;

    /// @notice Provider-agnostic USD price oracle (IPriceOracle).
    address internal _oracle;

    // ============ Liquidation parameters (basis points) ============

    /// @notice Max fraction of a market's debt repayable per HF-triggered liquidation.
    /// @dev Partial close (e.g. 5000 = 50%) to avoid over-liquidating a merely-unhealthy
    ///      position. Must be in (0, BPS].
    uint256 internal _hfCloseFactorBps;

    /// @notice Max fraction of a market's debt repayable per matured/default liquidation.
    /// @dev A matured loan is simply due, so this is typically 10000 (100%).
    uint256 internal _maturedCloseFactorBps;

    /// @notice Default liquidation bonus applied when a collateral asset has no override.
    /// @dev e.g. 800 = 8% extra collateral handed to the liquidator as incentive.
    uint256 internal _defaultLiquidationBonusBps;

    /// @notice Per-collateral-asset liquidation bonus override (0 = use default).
    mapping(address => uint256) internal _liquidationBonusBps;

    // ============ Pause ============

    /// @notice Whether liquidations are paused.
    bool internal _paused;

    /// @notice Guardian allowed to pause/unpause (fast emergency path, no timelock).
    address internal _pauser;

    // ============ Storage Gap ============

    /// @notice Storage gap for future upgrades.
    /// @dev ~9 slots used above (4 addresses + 3 uints + 1 mapping + a packed
    ///      bool/address slot). Reduce this gap when appending new variables.
    uint256[40] private __gap;
}
