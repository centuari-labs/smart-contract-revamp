// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MockChainlinkFeed
/// @notice Mock implementation of Chainlink AggregatorV3Interface for testing
/// @dev Configurable price, decimals, and timestamp for simulating various oracle states
contract MockChainlinkFeed {
    int256 private _price;
    uint8 private _decimals;
    uint256 private _updatedAt;
    uint80 private _roundId;
    string private _description;

    constructor(uint8 decimals_, string memory description_) {
        _decimals = decimals_;
        _description = description_;
        _roundId = 1;
        _updatedAt = block.timestamp;
    }

    /// @notice Set the mock price and update timestamp
    function setPrice(int256 price) external {
        _price = price;
        _updatedAt = block.timestamp;
        _roundId++;
    }

    /// @notice Set price with a specific timestamp (for staleness testing)
    function setPriceAt(int256 price, uint256 updatedAt) external {
        _price = price;
        _updatedAt = updatedAt;
        _roundId++;
    }

    /// @notice Make the feed stale by setting updatedAt to a past time
    function setStale(uint256 secondsAgo) external {
        _updatedAt = block.timestamp - secondsAgo;
    }

    // ============ AggregatorV3Interface ============

    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) {
        return (_roundId, _price, _updatedAt, _updatedAt, _roundId);
    }

    function getRoundData(uint80) external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) {
        return (_roundId, _price, _updatedAt, _updatedAt, _roundId);
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function description() external view returns (string memory) {
        return _description;
    }

    function version() external pure returns (uint256) {
        return 4;
    }
}
