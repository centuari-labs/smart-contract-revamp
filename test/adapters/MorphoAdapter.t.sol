// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MorphoAdapter} from "../../src/adapters/MorphoAdapter.sol";
import {MockToken} from "../../src/mocks/MockToken.sol";
import {MockMorphoBlue} from "../../src/mocks/MockMorphoBlue.sol";

contract MorphoAdapterTest is Test {
    MorphoAdapter public adapter;
    MockMorphoBlue public morpho;
    MockToken public token;

    // This test contract acts as the YieldRouter (passes address(this) as yieldRouter_)
    // so it satisfies the onlyRouter modifier without needing vm.prank.

    uint256 constant DEPLOY_AMOUNT = 1_000e6;

    function setUp() public {
        token = new MockToken("USD Coin", "USDC", 6, 0);
        morpho = new MockMorphoBlue(address(token));
        adapter = new MorphoAdapter(address(morpho), address(this));

        // Mint tokens to this test contract so it can act as the router
        token.mint(address(this), 100_000e6);
        token.approve(address(adapter), type(uint256).max);
    }

    // ============ test_deploy_returns_shares ============

    function test_deploy_returns_shares() public {
        uint256 shares = adapter.deploy(address(token), DEPLOY_AMOUNT);

        // First deploy: Morpho mock returns amount as shares (1:1, totalShares was 0)
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
        assertEq(adapter.getAPY(address(token)), 350);
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
        vm.expectRevert("MorphoAdapter: insufficient");
        adapter.recall(address(token), 1);
    }

    // ============ test_deploy_only_router_reverts ============

    function test_deploy_only_router_reverts() public {
        address nonRouter = address(0x99);
        vm.prank(nonRouter);
        vm.expectRevert("MorphoAdapter: only router");
        adapter.deploy(address(token), DEPLOY_AMOUNT);
    }

    // ============ test_recall_only_router_reverts ============

    function test_recall_only_router_reverts() public {
        address nonRouter = address(0x99);
        vm.prank(nonRouter);
        vm.expectRevert("MorphoAdapter: only router");
        adapter.recall(address(token), 1);
    }

    // ============ test_yield_injection_increases_share_value ============

    function test_yield_injection_increases_share_value() public {
        // Deploy initial amount
        uint256 shares = adapter.deploy(address(token), DEPLOY_AMOUNT);

        // Inject yield directly into Morpho (simulates interest accrual)
        uint256 yieldAmount = 50e6; // 5% yield
        token.mint(address(this), yieldAmount);
        token.approve(address(morpho), yieldAmount);
        morpho.injectYield(yieldAmount);

        // Morpho's share value has increased: the mock now holds more assets
        // The adapter's internal _totalDeployed is unchanged, but the mock's
        // totalAssets grew. The mock will return more tokens than shares represent
        // internally, so the extra tokens end up in the adapter. This is the expected
        // behavior — the adapter's accounting is conservative (tracks cost basis).
        uint256 deployedValue = adapter.getDeployedValue(address(token), shares);
        assertEq(deployedValue, DEPLOY_AMOUNT); // adapter tracks original deployment

        // Total morpho share value is now DEPLOY_AMOUNT + yieldAmount
        assertEq(morpho.getShareValue(shares), DEPLOY_AMOUNT + yieldAmount);
    }

    // ============ test_second_deploy_proportional_shares ============

    function test_second_deploy_proportional_shares() public {
        uint256 shares1 = adapter.deploy(address(token), DEPLOY_AMOUNT);

        token.mint(address(this), DEPLOY_AMOUNT);
        uint256 shares2 = adapter.deploy(address(token), DEPLOY_AMOUNT);

        // Second deploy at same ratio, no yield injected
        assertEq(shares2, DEPLOY_AMOUNT);
        assertEq(adapter.getDeployedValue(address(token), shares1 + shares2), DEPLOY_AMOUNT * 2);
    }

    // ============ testFuzz_deploy_and_recall_roundtrip ============

    function testFuzz_deploy_and_recall_roundtrip(uint256 amount) public {
        amount = bound(amount, 1e6, 1_000_000e6);

        token.mint(address(this), amount);
        uint256 balanceBefore = token.balanceOf(address(this));

        uint256 shares = adapter.deploy(address(token), amount);
        assertEq(shares, amount); // First deploy is always 1:1 (Morpho mock starts with 0 shares)

        uint256 returned = adapter.recall(address(token), shares);
        assertEq(returned, amount);
        assertEq(token.balanceOf(address(this)), balanceBefore);
    }
}
