// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ChainlinkPriceFeed} from "../../src/core/oracle/ChainlinkPriceFeed.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";

contract ChainlinkPriceFeedTest is Test {
    function test_normalizes8DecimalsTo1e18() public {
        // BTC at $60,000 with an 8-decimal feed
        MockAggregatorV3 agg = new MockAggregatorV3(8, 60_000e8, 1000);
        ChainlinkPriceFeed feed = new ChainlinkPriceFeed(address(agg));
        (uint256 p, uint256 u) = feed.latestPriceUsd();
        assertEq(p, 60_000e18);
        assertEq(u, 1000);
        assertEq(feed.FEED_DECIMALS(), 8);
    }

    function test_normalizes18DecimalFeed() public {
        MockAggregatorV3 agg = new MockAggregatorV3(18, 3_000e18, 500);
        ChainlinkPriceFeed feed = new ChainlinkPriceFeed(address(agg));
        (uint256 p,) = feed.latestPriceUsd();
        assertEq(p, 3_000e18);
    }

    function test_nonpositiveAnswerReturnsZeroPrice() public {
        MockAggregatorV3 agg = new MockAggregatorV3(8, int256(0), 1000);
        ChainlinkPriceFeed feed = new ChainlinkPriceFeed(address(agg));
        (uint256 p,) = feed.latestPriceUsd();
        assertEq(p, 0);

        agg.setAnswer(-5, 1001);
        (uint256 p2,) = feed.latestPriceUsd();
        assertEq(p2, 0);
    }

    function test_zeroAggregatorReverts() public {
        vm.expectRevert(ChainlinkPriceFeed.ZeroAddress.selector);
        new ChainlinkPriceFeed(address(0));
    }
}
