// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {IMarketScheduleRegistry} from "../interfaces/IMarketScheduleRegistry.sol";
import {MarketScheduleRegistryStorage} from "./MarketScheduleRegistryStorage.sol";

/// @title MarketScheduleRegistry
/// @notice Stores market hours schedules for assets with hasMarketHours = true
/// @dev RiskModule reads this to apply after-hours LTV buffers.
///      Supports multiple exchanges (NYSE, LSE, TSE, IDX, SGX, HKEX, etc.).
contract MarketScheduleRegistry is
    Initializable,
    OwnableUpgradeable,
    MarketScheduleRegistryStorage,
    IMarketScheduleRegistry
{
    // ============ Constructor ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initializer ============

    function initialize(address owner_) external initializer {
        if (owner_ == address(0)) revert Unauthorized();
        __Ownable_init(owner_);
    }

    // ============ Schedule Management ============

    /// @inheritdoc IMarketScheduleRegistry
    function addSchedule(
        bytes32 scheduleId,
        MarketSchedule calldata schedule
    ) external override onlyOwner {
        if (_scheduleExists[scheduleId]) revert ScheduleAlreadyExists(scheduleId);
        if (schedule.tradingDays.length == 0) revert InvalidSchedule();
        if (schedule.openTimeUTC >= schedule.closeTimeUTC) revert InvalidSchedule();

        _schedules[scheduleId] = schedule;
        _scheduleExists[scheduleId] = true;

        emit ScheduleAdded(scheduleId, schedule.exchangeId);
    }

    /// @inheritdoc IMarketScheduleRegistry
    function updateSchedule(
        bytes32 scheduleId,
        MarketSchedule calldata schedule
    ) external override onlyOwner {
        if (!_scheduleExists[scheduleId]) revert ScheduleNotFound(scheduleId);
        if (schedule.tradingDays.length == 0) revert InvalidSchedule();
        if (schedule.openTimeUTC >= schedule.closeTimeUTC) revert InvalidSchedule();

        _schedules[scheduleId] = schedule;

        emit ScheduleUpdated(scheduleId);
    }

    /// @inheritdoc IMarketScheduleRegistry
    function isOpen(bytes32 scheduleId) external view override returns (bool) {
        if (!_scheduleExists[scheduleId]) revert ScheduleNotFound(scheduleId);

        MarketSchedule storage s = _schedules[scheduleId];

        // Check day of week (1=Mon, 7=Sun)
        uint8 dayOfWeek = _getDayOfWeek(block.timestamp);
        bool isTradingDay = false;
        for (uint256 i = 0; i < s.tradingDays.length; i++) {
            if (s.tradingDays[i] == dayOfWeek) {
                isTradingDay = true;
                break;
            }
        }
        if (!isTradingDay) return false;

        // Check if today is a holiday
        uint256 todayStart = (block.timestamp / 1 days) * 1 days;
        for (uint256 i = 0; i < s.holidays.length; i++) {
            uint256 holidayStart = (s.holidays[i] / 1 days) * 1 days;
            if (todayStart == holidayStart) return false;
        }

        // Check time of day (seconds from midnight UTC)
        uint256 timeOfDay = block.timestamp % 1 days;
        return timeOfDay >= s.openTimeUTC && timeOfDay < s.closeTimeUTC;
    }

    /// @inheritdoc IMarketScheduleRegistry
    function getSchedule(bytes32 scheduleId) external view override returns (MarketSchedule memory) {
        if (!_scheduleExists[scheduleId]) revert ScheduleNotFound(scheduleId);
        return _schedules[scheduleId];
    }

    // ============ Internal ============

    /// @notice Get day of week from timestamp (1=Mon, 7=Sun)
    /// @dev Uses the fact that Jan 1, 1970 was a Thursday (day 4)
    function _getDayOfWeek(uint256 timestamp) internal pure returns (uint8) {
        // Days since epoch
        uint256 daysSinceEpoch = timestamp / 1 days;
        // Jan 1, 1970 = Thursday = day 4 (1=Mon...7=Sun)
        // daysSinceEpoch 0 = Thursday = 4
        uint8 dayOfWeek = uint8(((daysSinceEpoch + 3) % 7) + 1);
        return dayOfWeek;
    }
}
