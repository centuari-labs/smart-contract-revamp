// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPriceOracle} from "../../interfaces/IPriceOracle.sol";
import {ICentuari} from "../../interfaces/ICentuari.sol";
import {IBalanceLedger} from "../../interfaces/IBalanceLedger.sol";

/// @title RiskModuleStorage
/// @notice Storage layout for the upgradeable RiskModule.
/// @dev IMPORTANT: only append new storage variables to the end. Never reorder,
///      remove, or change types of existing variables.
abstract contract RiskModuleStorage {
    // ============ Storage Variables ============

    /// @notice USD price oracle (provider-agnostic `IPriceOracle` seam).
    IPriceOracle internal _oracle;

    /// @notice Centuari lending contract — source of per-user debt enumeration.
    ICentuari internal _centuari;

    /// @notice BalanceLedger — source of flagged collateral + available balances.
    IBalanceLedger internal _balanceLedger;

    /// @notice Per-collateral-asset loan-to-value in basis points.
    /// @dev 0 = the asset contributes no borrowing power (conservative default).
    mapping(address => uint256) internal _ltvBps;

    /// @notice Per-collateral-asset HF buffer in basis points.
    /// @dev 0 = fall back to `_defaultBufferBps`.
    mapping(address => uint256) internal _bufferBps;

    /// @notice Default HF buffer (bps) applied when an asset has no explicit buffer.
    /// @dev Mirrors the off-chain `DEFAULT_BORROW_BUFFER_BPS` (100 = 1.01 threshold).
    uint256 internal _defaultBufferBps;

    // ============ Storage Gap ============

    /// @notice Storage gap for future upgrades (6 slots used above).
    uint256[44] private __gap;
}
