// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SpokePayout} from "../../src/spoke/SpokePayout.sol";
import {MockToken} from "../../src/mocks/MockToken.sol";

contract SpokePayoutTest is Test {
    SpokePayout public payout;
    MockToken public token;

    address public owner = address(0x1);
    address public withdrawalRegistry = address(0x2);
    address public user = address(0x10);
    address public unauthorized = address(0x20);

    bytes32 constant REQUEST_ID = keccak256("request-1");
    bytes32 constant REQUEST_ID_2 = keccak256("request-2");
    uint256 constant PAYOUT_AMOUNT = 1_000e6;

    function setUp() public {
        token = new MockToken("USD Coin", "USDC", 6, 0);

        vm.prank(owner);
        payout = new SpokePayout(owner);

        vm.startPrank(owner);
        payout.setWithdrawalRegistry(withdrawalRegistry);
        vm.stopPrank();

        // Fund the payout contract with tokens
        token.mint(address(payout), 100_000e6);
    }

    // ============ test_authorize_stores_details ============

    function test_authorize_stores_details() public {
        vm.prank(withdrawalRegistry);
        payout.authorize(REQUEST_ID, user, address(token), PAYOUT_AMOUNT);

        (address storedUser, address storedAsset, uint256 storedAmount, bool authorized, bool released) =
            payout.authorizations(REQUEST_ID);

        assertEq(storedUser, user);
        assertEq(storedAsset, address(token));
        assertEq(storedAmount, PAYOUT_AMOUNT);
        assertTrue(authorized);
        assertFalse(released);
    }

    // ============ test_release_uses_stored_details ============

    function test_release_uses_stored_details() public {
        vm.prank(withdrawalRegistry);
        payout.authorize(REQUEST_ID, user, address(token), PAYOUT_AMOUNT);

        uint256 userBefore = token.balanceOf(user);
        uint256 vaultBefore = token.balanceOf(address(payout));

        vm.expectEmit(true, true, true, true);
        emit SpokePayout.Released(REQUEST_ID, user, address(token), PAYOUT_AMOUNT);

        payout.release(REQUEST_ID);

        assertEq(token.balanceOf(user), userBefore + PAYOUT_AMOUNT);
        assertEq(token.balanceOf(address(payout)), vaultBefore - PAYOUT_AMOUNT);

        (, , , , bool released) = payout.authorizations(REQUEST_ID);
        assertTrue(released);
    }

    // ============ test_release_unauthorized_reverts ============

    function test_release_unauthorized_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(SpokePayout.NotAuthorized.selector, REQUEST_ID));
        payout.release(REQUEST_ID);
    }

    // ============ test_release_queues_when_insufficient ============

    function test_release_queues_when_insufficient() public {
        // Drain payout contract
        uint256 balance = token.balanceOf(address(payout));
        // Use a fresh request with amount larger than balance + 1
        uint256 largeAmount = balance + 1;
        token.mint(address(payout), 0); // no-op, just confirm balance exists

        // Create a new payout contract with no funds
        vm.prank(owner);
        SpokePayout emptyPayout = new SpokePayout(owner);
        vm.prank(owner);
        emptyPayout.setWithdrawalRegistry(withdrawalRegistry);

        vm.prank(withdrawalRegistry);
        emptyPayout.authorize(REQUEST_ID, user, address(token), PAYOUT_AMOUNT);

        vm.expectEmit(true, true, true, true);
        emit SpokePayout.Queued(REQUEST_ID, user, address(token), PAYOUT_AMOUNT);

        emptyPayout.release(REQUEST_ID);

        assertEq(emptyPayout.queueLength(), 1);
        assertEq(token.balanceOf(user), 0); // nothing transferred
    }

    // ============ test_processQueued_releases_after_funding ============

    function test_processQueued_releases_after_funding() public {
        // Set up an empty payout contract
        vm.prank(owner);
        SpokePayout emptyPayout = new SpokePayout(owner);
        vm.prank(owner);
        emptyPayout.setWithdrawalRegistry(withdrawalRegistry);

        // Authorize and queue (insufficient funds)
        vm.prank(withdrawalRegistry);
        emptyPayout.authorize(REQUEST_ID, user, address(token), PAYOUT_AMOUNT);
        emptyPayout.release(REQUEST_ID);

        assertEq(emptyPayout.queueLength(), 1);

        // Fund the payout contract
        token.mint(address(emptyPayout), PAYOUT_AMOUNT);

        uint256 userBefore = token.balanceOf(user);

        vm.expectEmit(true, true, true, true);
        emit SpokePayout.QueuedReleaseProcessed(REQUEST_ID, user, address(token), PAYOUT_AMOUNT);

        emptyPayout.processQueued();

        assertEq(token.balanceOf(user), userBefore + PAYOUT_AMOUNT);
        assertEq(emptyPayout.queueLength(), 0);
    }

    // ============ test_release_already_released_reverts ============

    function test_release_already_released_reverts() public {
        vm.prank(withdrawalRegistry);
        payout.authorize(REQUEST_ID, user, address(token), PAYOUT_AMOUNT);

        payout.release(REQUEST_ID);

        vm.expectRevert(abi.encodeWithSelector(SpokePayout.AlreadyReleased.selector, REQUEST_ID));
        payout.release(REQUEST_ID);
    }

    // ============ test_authorize_only_registry_or_owner ============

    function test_authorize_only_registry_or_owner() public {
        // Unauthorized caller reverts
        vm.prank(unauthorized);
        vm.expectRevert("SpokePayout: unauthorized");
        payout.authorize(REQUEST_ID, user, address(token), PAYOUT_AMOUNT);

        // Owner can authorize
        vm.prank(owner);
        payout.authorize(REQUEST_ID, user, address(token), PAYOUT_AMOUNT);
        (, , , bool authorized, ) = payout.authorizations(REQUEST_ID);
        assertTrue(authorized);

        // WithdrawalRegistry can authorize
        vm.prank(withdrawalRegistry);
        payout.authorize(REQUEST_ID_2, user, address(token), PAYOUT_AMOUNT);
        (, , , bool authorized2, ) = payout.authorizations(REQUEST_ID_2);
        assertTrue(authorized2);
    }
}
