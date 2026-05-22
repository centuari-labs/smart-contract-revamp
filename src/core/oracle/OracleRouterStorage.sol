// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPriceFeed} from "../../interfaces/IPriceFeed.sol";

/// @title OracleRouterStorage
/// @notice Storage layout for the upgradeable OracleRouter.
/// @dev IMPORTANT: only append new storage variables to the end. Never reorder,
///      remove, or change types of existing variables.
abstract contract OracleRouterStorage {
    // ============ Storage Variables ============

    /// @notice Per-asset price source (Chainlink adapter, push, or custom).
    /// @dev `address(0)` means the asset is unpriced → router fail-closes.
    mapping(address => IPriceFeed) internal _feeds;

    /// @notice Per-asset max acceptable price age in seconds.
    /// @dev `0` disables the staleness gate for that asset.
    mapping(address => uint256) internal _maxStaleness;

    // ============ Storage Gap ============

    /// @notice Storage gap for future upgrades (2 mapping slots used above).
    uint256[48] private __gap;
}
