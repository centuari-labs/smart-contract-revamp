// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ChainlinkPriceFeed} from "../../src/core/oracle/ChainlinkPriceFeed.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";

contract ChainlinkPriceFeedTest is Test {
    function test_normalizes8DecimalsTo1e18() public {
        // BTC at $60,000 with an 8-decimal feed
        MockAggregatorV3 agg = new MockAggregatorV3(8, 60_000e8, 1000);
        ChainlinkPriceFeed feed = new ChainlinkPriceFeed(address(agg), address(0));
        (uint256 p, uint256 u) = feed.latestPriceUsd();
        assertEq(p, 60_000e18);
        assertEq(u, 1000);
        assertEq(feed.FEED_DECIMALS(), 8);
    }

    function test_normalizes18DecimalFeed() public {
        MockAggregatorV3 agg = new MockAggregatorV3(18, 3_000e18, 500);
        ChainlinkPriceFeed feed = new ChainlinkPriceFeed(address(agg), address(0));
        (uint256 p,) = feed.latestPriceUsd();
        assertEq(p, 3_000e18);
    }

    function test_nonpositiveAnswerReturnsZeroPrice() public {
        MockAggregatorV3 agg = new MockAggregatorV3(8, int256(0), 1000);
        ChainlinkPriceFeed feed = new ChainlinkPriceFeed(address(agg), address(0));
        (uint256 p,) = feed.latestPriceUsd();
        assertEq(p, 0);

        agg.setAnswer(-5, 1001);
        (uint256 p2,) = feed.latestPriceUsd();
        assertEq(p2, 0);
    }

    function test_zeroAggregatorReverts() public {
        vm.expectRevert(ChainlinkPriceFeed.ZeroAddress.selector);
        new ChainlinkPriceFeed(address(0), address(0));
    }

    // ============ SC-4: round completeness ============

    /// @dev answeredInRound < roundId means the answer carried over from an earlier
    ///      round and was never refreshed → fail-closed.
    function test_staleRound_answeredInRoundBehind_failsClosed() public {
        MockAggregatorV3 agg = new MockAggregatorV3(8, 60_000e8, 1000);
        agg.setRoundData(5, 60_000e8, 1000, 1000, 4); // answeredInRound (4) < roundId (5)
        ChainlinkPriceFeed feed = new ChainlinkPriceFeed(address(agg), address(0));
        (uint256 p,) = feed.latestPriceUsd();
        assertEq(p, 0);
    }

    function test_zeroStartedAt_failsClosed() public {
        MockAggregatorV3 agg = new MockAggregatorV3(8, 60_000e8, 1000);
        agg.setRoundData(5, 60_000e8, 0, 1000, 5); // startedAt == 0
        ChainlinkPriceFeed feed = new ChainlinkPriceFeed(address(agg), address(0));
        (uint256 p,) = feed.latestPriceUsd();
        assertEq(p, 0);
    }

    function test_completeRound_returnsPrice() public {
        MockAggregatorV3 agg = new MockAggregatorV3(8, 60_000e8, 1000);
        agg.setRoundData(7, 60_000e8, 999, 1000, 7); // complete: answeredInRound == roundId, startedAt != 0
        ChainlinkPriceFeed feed = new ChainlinkPriceFeed(address(agg), address(0));
        (uint256 p,) = feed.latestPriceUsd();
        assertEq(p, 60_000e18);
    }

    // ============ SC-4: L2 sequencer uptime ============

    function _sequencer(int256 status, uint256 startedAt) internal returns (MockAggregatorV3 seq) {
        seq = new MockAggregatorV3(0, status, startedAt);
        seq.setRoundData(1, status, startedAt, startedAt, 1);
    }

    function test_sequencerDown_failsClosed() public {
        vm.warp(100_000);
        MockAggregatorV3 agg = new MockAggregatorV3(8, 60_000e8, 100_000);
        MockAggregatorV3 seq = _sequencer(1, 90_000); // 1 = down
        ChainlinkPriceFeed feed = new ChainlinkPriceFeed(address(agg), address(seq));
        (uint256 p,) = feed.latestPriceUsd();
        assertEq(p, 0);
    }

    function test_sequencerUp_withinGrace_failsClosed() public {
        vm.warp(100_000);
        MockAggregatorV3 agg = new MockAggregatorV3(8, 60_000e8, 100_000);
        MockAggregatorV3 seq = _sequencer(0, 100_000 - 100); // up, but only 100s ago (< 3600 grace)
        ChainlinkPriceFeed feed = new ChainlinkPriceFeed(address(agg), address(seq));
        (uint256 p,) = feed.latestPriceUsd();
        assertEq(p, 0);
    }

    function test_sequencerUp_pastGrace_returnsPrice() public {
        vm.warp(100_000);
        MockAggregatorV3 agg = new MockAggregatorV3(8, 60_000e8, 100_000);
        MockAggregatorV3 seq = _sequencer(0, 100_000 - 3601); // up, past the 3600s grace
        ChainlinkPriceFeed feed = new ChainlinkPriceFeed(address(agg), address(seq));
        (uint256 p,) = feed.latestPriceUsd();
        assertEq(p, 60_000e18);
    }
}
