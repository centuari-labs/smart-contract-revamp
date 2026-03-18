// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title DateTime
/// @notice Library for converting unix timestamps to human-readable date components
/// @dev Used for generating bond token names like "CBT USDC 1 Jan 2025"
library DateTime {
    /// @notice Seconds in a day
    uint256 constant SECONDS_PER_DAY = 24 * 60 * 60;

    /// @notice Days offset from unix epoch (1970) to year 0 in the algorithm
    int256 constant OFFSET19700101 = 2440588;

    /// @notice Get year, month, day from unix timestamp
    /// @param timestamp Unix timestamp
    /// @return year The year (e.g., 2025)
    /// @return month The month (1-12)
    /// @return day The day (1-31)
    function timestampToDate(uint256 timestamp)
        internal
        pure
        returns (uint256 year, uint256 month, uint256 day)
    {
        unchecked {
            int256 L = int256(timestamp / SECONDS_PER_DAY) + 68569 + OFFSET19700101;
            int256 N = (4 * L) / 146097;
            L = L - (146097 * N + 3) / 4;
            int256 _year = (4000 * (L + 1)) / 1461001;
            L = L - (1461 * _year) / 4 + 31;
            int256 _month = (80 * L) / 2447;
            int256 _day = L - (2447 * _month) / 80;
            L = _month / 11;
            _month = _month + 2 - 12 * L;
            _year = 100 * (N - 49) + _year + L;

            year = uint256(_year);
            month = uint256(_month);
            day = uint256(_day);
        }
    }

    /// @notice Get uppercase month abbreviation for symbol (JAN, FEB, etc.)
    /// @param month The month number (1-12)
    /// @return The 3-letter uppercase month abbreviation
    function getMonthAbbreviationUpper(uint256 month) internal pure returns (string memory) {
        if (month == 1) return "JAN";
        if (month == 2) return "FEB";
        if (month == 3) return "MAR";
        if (month == 4) return "APR";
        if (month == 5) return "MAY";
        if (month == 6) return "JUN";
        if (month == 7) return "JUL";
        if (month == 8) return "AUG";
        if (month == 9) return "SEP";
        if (month == 10) return "OCT";
        if (month == 11) return "NOV";
        if (month == 12) return "DEC";
        return "";
    }

    /// @notice Format date as "1 Jan 2025"
    /// @param timestamp Unix timestamp
    /// @return Formatted date string
    function formatDate(uint256 timestamp) internal pure returns (string memory) {
        (uint256 year, uint256 month, uint256 day) = timestampToDate(timestamp);
        return string(
            abi.encodePacked(
                uintToString(day),
                " ",
                getMonthAbbreviationUpper(month),
                " ",
                uintToString(year)
            )
        );
    }

    /// @notice Format date for symbol as "1JAN25"
    /// @param timestamp Unix timestamp
    /// @return Formatted date string for symbol
    function formatDateSymbol(uint256 timestamp) internal pure returns (string memory) {
        (uint256 year, uint256 month, uint256 day) = timestampToDate(timestamp);
        // Get last 2 digits of year
        uint256 yearShort = year % 100;
        return string(
            abi.encodePacked(
                uintToString(day),
                getMonthAbbreviationUpper(month),
                uintToString(yearShort)
            )
        );
    }

    /// @notice Get mixed-case month name for display (Jan, Feb, etc.)
    function getMonthName(uint256 month) internal pure returns (string memory) {
        if (month == 1) return "Jan";
        if (month == 2) return "Feb";
        if (month == 3) return "Mar";
        if (month == 4) return "Apr";
        if (month == 5) return "May";
        if (month == 6) return "Jun";
        if (month == 7) return "Jul";
        if (month == 8) return "Aug";
        if (month == 9) return "Sep";
        if (month == 10) return "Oct";
        if (month == 11) return "Nov";
        if (month == 12) return "Dec";
        return "";
    }

    /// @notice Format date as ISO "2026-06-01" for CBT symbol (architecture §3.4)
    function formatDateISO(uint256 timestamp) internal pure returns (string memory) {
        (uint256 year, uint256 month, uint256 day) = timestampToDate(timestamp);
        return string(
            abi.encodePacked(
                uintToString(year),
                "-",
                month < 10 ? "0" : "",
                uintToString(month),
                "-",
                day < 10 ? "0" : "",
                uintToString(day)
            )
        );
    }

    /// @notice Format name as "Centuari Bond USDC Jun 2026" (architecture §3.5)
    function formatBondName(string memory tokenSymbol, uint256 timestamp) internal pure returns (string memory) {
        (uint256 year, uint256 month,) = timestampToDate(timestamp);
        return string(
            abi.encodePacked(
                "Centuari Bond ",
                tokenSymbol,
                " ",
                getMonthName(month),
                " ",
                uintToString(year)
            )
        );
    }

    /// @notice Format symbol as "CBT-USDC-2026-06-01" (architecture §3.4)
    function formatBondSymbol(string memory tokenSymbol, uint256 timestamp) internal pure returns (string memory) {
        return string(
            abi.encodePacked(
                "CBT-",
                tokenSymbol,
                "-",
                formatDateISO(timestamp)
            )
        );
    }

    /// @notice Convert uint to string
    /// @param value The uint value to convert
    /// @return The string representation
    function uintToString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}

