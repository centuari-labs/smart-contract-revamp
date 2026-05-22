// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPriceFeed} from "../../interfaces/IPriceFeed.sol";
import {AggregatorV3Interface} from "../../interfaces/external/AggregatorV3Interface.sol";

/// @title ChainlinkPriceFeed
/// @notice `IPriceFeed` adapter that wraps a single Chainlink USD aggregator.
/// @dev One instance per Chainlink-priced asset. Normalizes the aggregator's
///      native decimals to 1e18 and passes `updatedAt` through for the router's
///      staleness gate. Returns price 0 on a non-positive answer so the router
///      fail-closes; a reverting aggregator is caught by the router's try/catch.
contract ChainlinkPriceFeed is IPriceFeed {
    /// @notice The wrapped Chainlink aggregator (USD-denominated)
    AggregatorV3Interface public immutable AGGREGATOR;

    /// @notice Cached `AGGREGATOR.decimals()` (Chainlink USD feeds are 8)
    uint8 public immutable FEED_DECIMALS;

    error ZeroAddress();

    /// @param aggregator_ The Chainlink USD aggregator for one asset
    constructor(address aggregator_) {
        if (aggregator_ == address(0)) revert ZeroAddress();
        AGGREGATOR = AggregatorV3Interface(aggregator_);
        FEED_DECIMALS = AggregatorV3Interface(aggregator_).decimals();
    }

    /// @inheritdoc IPriceFeed
    function latestPriceUsd() external view returns (uint256 price1e18, uint256 updatedAt) {
        (, int256 answer,, uint256 updatedAt_,) = AGGREGATOR.latestRoundData();
        if (answer <= 0) {
            return (0, updatedAt_);
        }
        uint256 raw = uint256(answer);
        if (FEED_DECIMALS <= 18) {
            price1e18 = raw * (10 ** (18 - FEED_DECIMALS));
        } else {
            price1e18 = raw / (10 ** (FEED_DECIMALS - 18));
        }
        updatedAt = updatedAt_;
    }
}
