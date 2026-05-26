// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AggregatorV3Interface} from "../../src/interfaces/external/AggregatorV3Interface.sol";

/// @title MockAggregatorV3
/// @notice Configurable Chainlink aggregator mock for oracle tests.
/// @dev By default `startedAt == updatedAt` and `answeredInRound == roundId`, so
///      a freshly-set answer passes ChainlinkPriceFeed's round-completeness gate.
///      Use `setRoundData` to forge incomplete rounds (e.g. answeredInRound <
///      roundId) or drive a sequencer-uptime feed (answer 0 = up, 1 = down).
contract MockAggregatorV3 is AggregatorV3Interface {
    uint8 private _decimals;
    int256 private _answer;
    uint256 private _startedAt;
    uint256 private _updatedAt;
    uint80 private _roundId;
    uint80 private _answeredInRound;
    bool private _shouldRevert;

    constructor(uint8 decimals_, int256 answer_, uint256 updatedAt_) {
        _decimals = decimals_;
        _answer = answer_;
        _updatedAt = updatedAt_;
        _startedAt = updatedAt_;
        _roundId = 1;
        _answeredInRound = 1;
    }

    function setAnswer(int256 answer_, uint256 updatedAt_) external {
        _answer = answer_;
        _updatedAt = updatedAt_;
        _startedAt = updatedAt_;
        _roundId += 1;
        _answeredInRound = _roundId;
    }

    /// @notice Forge the full round tuple (for round-completeness / sequencer tests).
    function setRoundData(
        uint80 roundId_,
        int256 answer_,
        uint256 startedAt_,
        uint256 updatedAt_,
        uint80 answeredInRound_
    ) external {
        _roundId = roundId_;
        _answer = answer_;
        _startedAt = startedAt_;
        _updatedAt = updatedAt_;
        _answeredInRound = answeredInRound_;
    }

    function setShouldRevert(bool v) external {
        _shouldRevert = v;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!_shouldRevert, "feed down");
        return (_roundId, _answer, _startedAt, _updatedAt, _answeredInRound);
    }
}
