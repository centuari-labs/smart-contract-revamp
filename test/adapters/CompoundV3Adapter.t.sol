// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CompoundV3Adapter} from "../../src/adapters/CompoundV3Adapter.sol";
import {MockToken} from "../../src/mocks/MockToken.sol";
import {MockCompoundV3Comet} from "../../src/mocks/MockCompoundV3Comet.sol";

contract CompoundV3AdapterTest is Test {
    CompoundV3Adapter public adapter;
    MockCompoundV3Comet public comet;
    MockToken public token;

    // This test contract acts as the YieldRouter (passes address(this) as yieldRouter_)
    // so it satisfies the onlyRouter modifier without needing vm.prank.

    uint256 constant DEPLOY_AMOUNT = 1_000e6;

    function setUp() public {
        token = new MockToken("USD Coin", "USDC", 6, 0);
        comet = new MockCompoundV3Comet(address(token));
        adapter = new CompoundV3Adapter(address(comet), address(this));

        // Mint tokens to this test contract so it can act as the router
        token.mint(address(this), 100_000e6);
        token.approve(address(adapter), type(uint256).max);
    }

    // ============ test_deploy_returns_shares ============

    function test_deploy_returns_shares() public {
        uint256 shares = adapter.deploy(address(token), DEPLOY_AMOUNT);

        // First deploy: 1:1 share issuance
        assertEq(shares, DEPLOY_AMOUNT);

        // getDeployedValue should reflect the deployed amount
        assertEq(adapter.getDeployedValue(address(token), shares), DEPLOY_AMOUNT);
    }

    // ============ test_recall_returns_amount ============

    function test_recall_returns_amount() public {
        uint256 balanceBefore = token.balanceOf(address(this));

        uint256 shares = adapter.deploy(address(token), DEPLOY_AMOUNT);

        // After deploy, tokens left the test contract
        assertEq(token.balanceOf(address(this)), balanceBefore - DEPLOY_AMOUNT);

        uint256 returned = adapter.recall(address(token), shares);

        assertEq(returned, DEPLOY_AMOUNT);
        // Tokens returned to the caller (this test contract, acting as router)
        assertEq(token.balanceOf(address(this)), balanceBefore);
    }

    // ============ test_getAPY_returns_value ============

    function test_getAPY_returns_value() public view {
        assertEq(adapter.getAPY(address(token)), 400);
    }

    // ============ test_isAvailable_returns_true ============

    function test_isAvailable_returns_true() public view {
        assertTrue(adapter.isAvailable(address(token)));
    }

    // ============ test_canRecall_true_after_deploy ============

    function test_canRecall_true_after_deploy() public {
        uint256 shares = adapter.deploy(address(token), DEPLOY_AMOUNT);

        assertTrue(adapter.canRecall(address(token), shares));
        // Requesting more shares than deployed returns false
        assertFalse(adapter.canRecall(address(token), shares + 1));
    }

    // ============ test_recall_insufficient_shares_reverts ============

    function test_recall_insufficient_shares_reverts() public {
        vm.expectRevert("CompoundV3Adapter: insufficient shares");
        adapter.recall(address(token), 1);
    }

    // ============ test_deploy_only_router_reverts ============

    function test_deploy_only_router_reverts() public {
        address nonRouter = address(0x99);
        vm.prank(nonRouter);
        vm.expectRevert("CompoundV3Adapter: only router");
        adapter.deploy(address(token), DEPLOY_AMOUNT);
    }

    // ============ test_recall_only_router_reverts ============

    function test_recall_only_router_reverts() public {
        address nonRouter = address(0x99);
        vm.prank(nonRouter);
        vm.expectRevert("CompoundV3Adapter: only router");
        adapter.recall(address(token), 1);
    }

    // ============ test_second_deploy_proportional_shares ============

    function test_second_deploy_proportional_shares() public {
        uint256 shares1 = adapter.deploy(address(token), DEPLOY_AMOUNT);

        token.mint(address(this), DEPLOY_AMOUNT);
        uint256 shares2 = adapter.deploy(address(token), DEPLOY_AMOUNT);

        assertEq(shares2, DEPLOY_AMOUNT);
        assertEq(adapter.getDeployedValue(address(token), shares1 + shares2), DEPLOY_AMOUNT * 2);
    }

    // ============ testFuzz_deploy_and_recall_roundtrip ============

    function testFuzz_deploy_and_recall_roundtrip(uint256 amount) public {
        amount = bound(amount, 1e6, 1_000_000e6);

        token.mint(address(this), amount);
        uint256 balanceBefore = token.balanceOf(address(this));

        uint256 shares = adapter.deploy(address(token), amount);
        assertEq(shares, amount); // First deploy is always 1:1

        uint256 returned = adapter.recall(address(token), shares);
        assertEq(returned, amount);
        assertEq(token.balanceOf(address(this)), balanceBefore);
    }
}
