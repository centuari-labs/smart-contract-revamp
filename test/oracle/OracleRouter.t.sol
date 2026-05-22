// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {OracleRouter} from "../../src/core/oracle/OracleRouter.sol";
import {IPriceFeed} from "../../src/interfaces/IPriceFeed.sol";
import {PushOracle} from "../../src/core/oracle/PushOracle.sol";
import {ChainlinkPriceFeed} from "../../src/core/oracle/ChainlinkPriceFeed.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {MockToken} from "../../src/mocks/MockToken.sol";

/// @notice A non-Chainlink, non-push price source — proves the router depends
///         only on `IPriceFeed`, so an in-house custom oracle plugs in too.
contract CustomPriceFeed is IPriceFeed {
    uint256 internal _p;
    uint256 internal _u;

    constructor(uint256 p, uint256 u) {
        _p = p;
        _u = u;
    }

    function set(uint256 p, uint256 u) external {
        _p = p;
        _u = u;
    }

    function latestPriceUsd() external view returns (uint256, uint256) {
        return (_p, _u);
    }
}

contract RevertingPriceFeed is IPriceFeed {
    function latestPriceUsd() external pure returns (uint256, uint256) {
        revert("feed down");
    }
}

contract OracleRouterTest is Test {
    OracleRouter internal router;
    address internal owner = makeAddr("owner");
    address internal operator = makeAddr("operator");
    address internal proxyAdminOwner = makeAddr("proxyAdminOwner");
    address internal stranger = makeAddr("stranger");

    MockToken internal usdc; // 6 decimals
    MockToken internal btc; // 8 decimals
    MockToken internal rwa; // 18 decimals

    function setUp() public {
        OracleRouter impl = new OracleRouter();
        bytes memory initData = abi.encodeCall(OracleRouter.initialize, (owner));
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(impl), proxyAdminOwner, initData);
        router = OracleRouter(address(proxy));

        usdc = new MockToken("USD Coin", "USDC", 6, 0);
        btc = new MockToken("Bitcoin", "BTC", 8, 0);
        rwa = new MockToken("Tether Gold", "XAUT", 18, 0);
    }

    function test_unregisteredAsset_failsClosed() public view {
        (uint256 v, bool ok) = router.tryGetUsdValue(address(usdc), 1_000e6);
        assertEq(v, 0);
        assertFalse(ok);
    }

    function test_pushOracle_valuation18decAsset() public {
        PushOracle feed = new PushOracle(owner, operator);
        vm.warp(1000);
        vm.prank(operator);
        feed.setPrice(2e18); // $2.00 per whole token

        vm.prank(owner);
        router.setFeed(address(rwa), address(feed));

        // 5 whole tokens @ $2 = $10
        (uint256 v, bool ok) = router.tryGetUsdValue(address(rwa), 5e18);
        assertTrue(ok);
        assertEq(v, 10e18);
    }

    function test_chainlinkBacked_valuation8decAsset() public {
        MockAggregatorV3 agg = new MockAggregatorV3(8, 60_000e8, 1000);
        ChainlinkPriceFeed feed = new ChainlinkPriceFeed(address(agg));
        vm.warp(1000);
        vm.prank(owner);
        router.setFeed(address(btc), address(feed));

        // 1 BTC (1e8) @ $60,000 = $60,000
        (uint256 v, bool ok) = router.tryGetUsdValue(address(btc), 1e8);
        assertTrue(ok);
        assertEq(v, 60_000e18);
    }

    function test_customFeed_pluggsIn_providerAgnostic() public {
        // Neither Chainlink nor PushOracle — a bespoke in-house source.
        vm.warp(1000);
        CustomPriceFeed feed = new CustomPriceFeed(1e18, 1000); // $1.00
        vm.prank(owner);
        router.setFeed(address(usdc), address(feed));

        // 1000 USDC (1000e6) @ $1 = $1000
        (uint256 v, bool ok) = router.tryGetUsdValue(address(usdc), 1_000e6);
        assertTrue(ok);
        assertEq(v, 1_000e18);
    }

    function test_zeroPrice_failsClosed() public {
        vm.warp(1000);
        CustomPriceFeed feed = new CustomPriceFeed(0, 1000);
        vm.prank(owner);
        router.setFeed(address(usdc), address(feed));
        (uint256 v, bool ok) = router.tryGetUsdValue(address(usdc), 1_000e6);
        assertEq(v, 0);
        assertFalse(ok);
    }

    function test_revertingFeed_failsClosed() public {
        RevertingPriceFeed feed = new RevertingPriceFeed();
        vm.prank(owner);
        router.setFeed(address(usdc), address(feed));
        (uint256 v, bool ok) = router.tryGetUsdValue(address(usdc), 1_000e6);
        assertEq(v, 0);
        assertFalse(ok);
    }

    function test_staleness_blocksWhenExpired() public {
        vm.warp(1000);
        CustomPriceFeed feed = new CustomPriceFeed(1e18, 1000);
        vm.startPrank(owner);
        router.setFeed(address(usdc), address(feed));
        router.setMaxStaleness(address(usdc), 3600);
        vm.stopPrank();

        // exactly at the boundary: still fresh
        vm.warp(1000 + 3600);
        (, bool okEdge) = router.tryGetUsdValue(address(usdc), 1_000e6);
        assertTrue(okEdge);

        // one second past the window: stale → fail-closed
        vm.warp(1000 + 3601);
        (uint256 v, bool ok) = router.tryGetUsdValue(address(usdc), 1_000e6);
        assertEq(v, 0);
        assertFalse(ok);
    }

    function test_staleness_zeroWindow_neverStale() public {
        vm.warp(1000);
        CustomPriceFeed feed = new CustomPriceFeed(1e18, 1000);
        vm.prank(owner);
        router.setFeed(address(usdc), address(feed));
        // no maxStaleness set (==0)

        vm.warp(1_000_000_000);
        (uint256 v, bool ok) = router.tryGetUsdValue(address(usdc), 1_000e6);
        assertTrue(ok);
        assertEq(v, 1_000e18);
    }

    function test_setFeed_onlyOwner() public {
        CustomPriceFeed feed = new CustomPriceFeed(1e18, 1000);
        vm.prank(stranger);
        vm.expectRevert();
        router.setFeed(address(usdc), address(feed));
    }

    function test_setMaxStaleness_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        router.setMaxStaleness(address(usdc), 3600);
    }

    function test_setFeed_updatesView() public {
        CustomPriceFeed feed = new CustomPriceFeed(1e18, 1000);
        vm.prank(owner);
        router.setFeed(address(usdc), address(feed));
        assertEq(router.feedOf(address(usdc)), address(feed));
    }
}
