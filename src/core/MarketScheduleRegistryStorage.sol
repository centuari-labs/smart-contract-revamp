// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IMarketScheduleRegistry} from "../interfaces/IMarketScheduleRegistry.sol";

/// @title MarketScheduleRegistryStorage
/// @notice Storage layout for MarketScheduleRegistry upgradeable contract
abstract contract MarketScheduleRegistryStorage {
    /// @notice Exchange schedules indexed by scheduleId
    mapping(bytes32 => IMarketScheduleRegistry.MarketSchedule) internal _schedules;

    /// @notice Track which scheduleIds exist
    mapping(bytes32 => bool) internal _scheduleExists;

    // ============ Gap ============

    uint256[48] private __gap;
}
