// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IMarketScheduleRegistry
/// @notice Stores market hours schedules for assets with hasMarketHours = true
/// @dev RiskModule reads this to apply after-hours LTV buffers.
///      Schedules are per-asset (not hardcoded to NYSE).
interface IMarketScheduleRegistry {
    // ============ Structs ============

    /// @notice Market hours schedule for an exchange
    struct MarketSchedule {
        string exchangeId;       // e.g., "NYSE", "LSE", "TSE"
        uint256 openTimeUTC;     // seconds from midnight UTC (e.g., 14:30 = 52200)
        uint256 closeTimeUTC;    // seconds from midnight UTC (e.g., 21:00 = 75600)
        uint8[] tradingDays;     // 1=Mon, 5=Fri (typically [1,2,3,4,5])
        uint256[] holidays;      // Unix timestamps of market holidays
    }

    // ============ Core Functions ============

    /// @notice Add a market schedule
    /// @param scheduleId The schedule identifier (bytes32)
    /// @param schedule The schedule configuration
    function addSchedule(bytes32 scheduleId, MarketSchedule calldata schedule) external;

    /// @notice Update an existing schedule
    function updateSchedule(bytes32 scheduleId, MarketSchedule calldata schedule) external;

    /// @notice Check if a market is currently open
    /// @param scheduleId The schedule identifier
    /// @return True if market is open
    function isOpen(bytes32 scheduleId) external view returns (bool);

    /// @notice Get a market schedule
    function getSchedule(bytes32 scheduleId) external view returns (MarketSchedule memory);

    // ============ Events ============

    event ScheduleAdded(bytes32 indexed scheduleId, string exchangeId);
    event ScheduleUpdated(bytes32 indexed scheduleId);

    // ============ Errors ============

    error Unauthorized();
    error ScheduleNotFound(bytes32 scheduleId);
    error ScheduleAlreadyExists(bytes32 scheduleId);
    error InvalidSchedule();
}
