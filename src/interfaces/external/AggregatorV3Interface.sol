// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title AggregatorV3Interface
/// @notice Minimal vendored Chainlink aggregator interface.
/// @dev Referenced ONLY by `ChainlinkPriceFeed`. Deliberately kept out of the
///      `OracleRouter` and `RiskModule` so the protocol stays provider-agnostic
///      (those depend on `IPriceOracle` / `IPriceFeed`, not on any vendor type).
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
