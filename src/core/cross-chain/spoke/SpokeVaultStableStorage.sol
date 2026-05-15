// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISpokeVaultStable} from "../../../interfaces/cross-chain/spoke/ISpokeVaultStable.sol";

/// @title SpokeVaultStableStorage
/// @notice Storage layout for the upgradeable SpokeVaultStable contract.
/// @dev IMPORTANT: Only append new storage variables to the end. Never reorder,
///      remove, or change the type of an existing variable. Reduce the
///      `__gap` by exactly the number of slots consumed when extending.
abstract contract SpokeVaultStableStorage {
    // ============ Per-asset accounting ============

    /// @notice BRIDGED token balances awaiting sweep to the hub via CCTP / Stargate.
    mapping(address => uint256) internal _bridgedBalance;

    /// @notice SPOKE_NATIVE token balances held in permanent local custody.
    mapping(address => uint256) internal _spokeNativeBalance;

    /// @notice Routing classification per registered asset.
    mapping(address => ISpokeVaultStable.AssetClassification) internal _classifications;

    /// @notice Per-asset Stargate router pointer (BRIDGED only).
    mapping(address => address) internal _stargateRouter;

    // ============ Roles ============

    /// @notice Address allowed to call `depositBridged` / `depositSpokeNative`.
    address internal _gateway;

    /// @notice Address allowed to call `sweepCCTP` / `sweepStargate`.
    address internal _sweeper;

    /// @notice Address allowed to call `releaseSpokeNative`. Wired to the
    ///         future SpokePayout in PR 4.
    address internal _payout;

    /// @notice Shared CCTP messenger pointer (one per spoke).
    address internal _cctpMessenger;

    // ============ Storage Gap ============

    /// @notice Storage gap for future upgrades.
    /// @dev Eight slots consumed by the four mappings + four address vars,
    ///      leaving 42 from the original 50-slot budget.
    uint256[42] private __gap;
}
