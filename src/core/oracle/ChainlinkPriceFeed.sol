// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPriceFeed} from "../../interfaces/IPriceFeed.sol";
import {AggregatorV3Interface} from "../../interfaces/external/AggregatorV3Interface.sol";

/// @title ChainlinkPriceFeed
/// @notice `IPriceFeed` adapter that wraps a single Chainlink USD aggregator.
/// @dev One instance per Chainlink-priced asset. Normalizes the aggregator's
///      native decimals to 1e18 and passes `updatedAt` through for the router's
///      staleness gate. Returns price 0 (fail-closed) on a non-positive answer,
///      an incomplete round, or — on L2 — a down/just-recovered sequencer; a
///      reverting aggregator is caught by the router's try/catch.
///
///      Vendor-specific safety (round completeness, L2 sequencer uptime) lives
///      HERE, inside the Chainlink adapter, so the OracleRouter and RiskModule
///      stay provider-agnostic. Dormant on Arb Sepolia (all assets currently use
///      PushOracle); wired only once a real Chainlink feed is available.
contract ChainlinkPriceFeed is IPriceFeed {
    /// @notice Grace period after the sequencer comes back up before trusting prices.
    uint256 private constant SEQUENCER_GRACE_PERIOD = 3600; // 1 hour

    /// @notice The wrapped Chainlink aggregator (USD-denominated)
    AggregatorV3Interface public immutable AGGREGATOR;

    /// @notice Optional Arbitrum L2 sequencer-uptime feed (address(0) = skip the
    ///         check, e.g. on L1 or testnets without a sequencer feed).
    AggregatorV3Interface public immutable SEQUENCER_UPTIME_FEED;

    /// @notice Cached `AGGREGATOR.decimals()` (Chainlink USD feeds are 8)
    uint8 public immutable FEED_DECIMALS;

    error ZeroAddress();

    /// @param aggregator_ The Chainlink USD aggregator for one asset
    /// @param sequencerUptimeFeed_ The L2 sequencer-uptime feed, or address(0) to
    ///        skip the sequencer check (L1 / testnet without a sequencer feed)
    constructor(address aggregator_, address sequencerUptimeFeed_) {
        if (aggregator_ == address(0)) revert ZeroAddress();
        AGGREGATOR = AggregatorV3Interface(aggregator_);
        FEED_DECIMALS = AggregatorV3Interface(aggregator_).decimals();
        SEQUENCER_UPTIME_FEED = AggregatorV3Interface(sequencerUptimeFeed_);
    }

    /// @inheritdoc IPriceFeed
    function latestPriceUsd() external view returns (uint256 price1e18, uint256 updatedAt) {
        // SC-4: on an L2 (Arbitrum), a Chainlink price can read fresh even though
        // the sequencer was down. When a sequencer-uptime feed is configured,
        // require the sequencer to be up AND past the grace period first.
        if (address(SEQUENCER_UPTIME_FEED) != address(0)) {
            (, int256 seqAnswer, uint256 seqStartedAt,,) = SEQUENCER_UPTIME_FEED.latestRoundData();
            // answer: 0 = up, 1 = down. startedAt = when the status last changed.
            if (seqAnswer != 0 || seqStartedAt == 0 || block.timestamp - seqStartedAt <= SEQUENCER_GRACE_PERIOD) {
                return (0, 0);
            }
        }

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt_, uint80 answeredInRound) =
            AGGREGATOR.latestRoundData();

        // SC-4: round completeness — reject non-positive, unset, or stale-round
        // answers (answeredInRound < roundId means the answer carried over from an
        // earlier round and was never refreshed). Fail-closed via price 0.
        if (answer <= 0 || updatedAt_ == 0 || startedAt == 0 || answeredInRound < roundId) {
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
