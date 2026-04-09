// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPCBT} from "../../interfaces/IPCBT.sol";

/// @title PCBTVaultStorage
/// @notice Storage layout for PCBTVault upgradeable contract (post-architecture-overhaul).
/// @dev Per-user rollover settings. No withdrawal queue (instant CBT withdrawal).
///      NEVER reorder or remove variables — only append before __gap and reduce gap size.
abstract contract PCBTVaultStorage {
    /// @notice Underlying loan token (USDC, IDRX, XSGD)
    address internal _loanToken;

    /// @notice Current active CBT contract held by vault
    address internal _currentCBT;

    /// @notice CentuariRateOracle for CBT fair value reads
    address internal _rateOracle;

    /// @notice BalanceLedger — vault deposits idle USDC here
    address internal _balanceLedger;

    /// @notice CentuariEndpoint — authorized caller for processMaturityResults
    address internal _endpoint;

    /// @notice Sum of all CBT face value held by vault
    uint256 internal _totalCBTHeld;

    /// @notice Next maturity timestamp (from currentCBT)
    uint256 internal _nextMaturity;

    /// @notice Per-user rollover settings
    mapping(address => IPCBT.RolloverSettings) internal _userSettings;

    /// @notice Settings lock: 1 hour before maturity
    uint256 internal constant SETTINGS_LOCK_DURATION = 1 hours;

    /// @notice Emergency wind-down grace period after maturity
    uint256 internal constant EMERGENCY_GRACE_PERIOD = 48 hours;

    /// @notice Virtual offset for inflation attack defense (10^6)
    uint256 internal constant VIRTUAL_OFFSET = 1e6;

    /// @notice Admin timelock duration
    uint256 internal constant ADMIN_TIMELOCK = 48 hours;

    /// @notice Pending admin address changes (48h timelock)
    mapping(bytes32 => address) internal _pendingAdminAddress;
    mapping(bytes32 => uint256) internal _pendingAdminTimelockEnd;

    // ============ Gap ============

    /// @dev Reserved for future upgrades.
    uint256[40] private __gap;
}
