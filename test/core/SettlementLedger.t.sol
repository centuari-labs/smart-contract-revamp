// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SettlementLedger} from "../../src/core/SettlementLedger.sol";
import {ISettlementLedger} from "../../src/interfaces/ISettlementLedger.sol";

contract SettlementLedgerTest is Test {
    SettlementLedger public ledger;

    address public owner = address(0x1);
    address public authorizedCaller = address(0x2);
    address public unauthorized = address(0x3);
    address public solver = address(0x10);

    bytes32 public constant ORDER_ID_A = keccak256("order-a");
    bytes32 public constant ORDER_ID_B = keccak256("order-b");

    function setUp() public {
        ledger = new SettlementLedger(owner);

        vm.warp(100000);
        vm.startPrank(owner);
        ledger.proposeAuthorizedCaller(authorizedCaller, true);
        vm.warp(100000 + 48 hours + 1);
        ledger.applyAuthorizedCaller(authorizedCaller);
        vm.stopPrank();
    }

    // ============ register ============

    function test_register_stores_fill() public {
        vm.expectEmit(true, true, false, true);
        emit ISettlementLedger.FillRegistered(ORDER_ID_A, solver, 1000e6);

        vm.prank(authorizedCaller);
        ledger.register(ORDER_ID_A, solver, 1000e6);

        (address storedSolver, uint256 storedAmount) = ledger.getPendingFill(ORDER_ID_A);
        assertEq(storedSolver, solver);
        assertEq(storedAmount, 1000e6);
    }

    function test_register_duplicate_reverts() public {
        vm.prank(authorizedCaller);
        ledger.register(ORDER_ID_A, solver, 1000e6);

        vm.prank(authorizedCaller);
        vm.expectRevert(abi.encodeWithSelector(ISettlementLedger.OrderAlreadyRegistered.selector, ORDER_ID_A));
        ledger.register(ORDER_ID_A, solver, 500e6);
    }

    // ============ matchFill ============

    function test_matchFill_marks_matched() public {
        vm.prank(authorizedCaller);
        ledger.register(ORDER_ID_A, solver, 1000e6);

        vm.expectEmit(true, true, false, true);
        emit ISettlementLedger.FillMatched(ORDER_ID_A, solver, 1000e6);

        vm.prank(authorizedCaller);
        ledger.matchFill(ORDER_ID_A, 1000e6);

        assertFalse(ledger.isPending(ORDER_ID_A));
    }

    function test_matchFill_unknown_order_reverts() public {
        vm.prank(authorizedCaller);
        vm.expectRevert(abi.encodeWithSelector(ISettlementLedger.OrderNotFound.selector, ORDER_ID_B));
        ledger.matchFill(ORDER_ID_B, 1000e6);
    }

    function test_matchFill_already_matched_reverts() public {
        vm.prank(authorizedCaller);
        ledger.register(ORDER_ID_A, solver, 1000e6);

        vm.prank(authorizedCaller);
        ledger.matchFill(ORDER_ID_A, 1000e6);

        // Second match on same order should revert (matched flag is set)
        vm.prank(authorizedCaller);
        vm.expectRevert(abi.encodeWithSelector(ISettlementLedger.OrderNotFound.selector, ORDER_ID_A));
        ledger.matchFill(ORDER_ID_A, 1000e6);
    }

    // ============ isPending ============

    function test_isPending_true_when_registered() public {
        vm.prank(authorizedCaller);
        ledger.register(ORDER_ID_A, solver, 500e6);

        assertTrue(ledger.isPending(ORDER_ID_A));
    }

    function test_isPending_false_when_matched() public {
        vm.prank(authorizedCaller);
        ledger.register(ORDER_ID_A, solver, 500e6);

        vm.prank(authorizedCaller);
        ledger.matchFill(ORDER_ID_A, 500e6);

        assertFalse(ledger.isPending(ORDER_ID_A));
    }

    function test_isPending_false_when_never_registered() public {
        assertFalse(ledger.isPending(ORDER_ID_B));
    }

    // ============ onlyAuthorized ============

    function test_onlyAuthorized_register_reverts_for_unknown_caller() public {
        vm.prank(unauthorized);
        vm.expectRevert(ISettlementLedger.Unauthorized.selector);
        ledger.register(ORDER_ID_A, solver, 1000e6);
    }

    function test_onlyAuthorized_matchFill_reverts_for_unknown_caller() public {
        vm.prank(authorizedCaller);
        ledger.register(ORDER_ID_A, solver, 1000e6);

        vm.prank(unauthorized);
        vm.expectRevert(ISettlementLedger.Unauthorized.selector);
        ledger.matchFill(ORDER_ID_A, 1000e6);
    }

    function test_owner_can_propose_authorized_caller() public {
        address newCaller = address(0x99);
        vm.startPrank(owner);
        ledger.proposeAuthorizedCaller(newCaller, true);
        vm.warp(block.timestamp + 48 hours + 1);
        ledger.applyAuthorizedCaller(newCaller);
        vm.stopPrank();

        // Should now succeed
        vm.prank(newCaller);
        ledger.register(ORDER_ID_A, solver, 1000e6);
        assertTrue(ledger.isPending(ORDER_ID_A));
    }

    function test_revoke_authorized_caller_blocks_access() public {
        vm.startPrank(owner);
        ledger.proposeAuthorizedCaller(authorizedCaller, false);
        vm.warp(block.timestamp + 48 hours + 1);
        ledger.applyAuthorizedCaller(authorizedCaller);
        vm.stopPrank();

        vm.prank(authorizedCaller);
        vm.expectRevert(ISettlementLedger.Unauthorized.selector);
        ledger.register(ORDER_ID_A, solver, 1000e6);
    }

    // ============ Fuzz ============

    function testFuzz_register_and_query(bytes32 orderId, address solverAddr, uint256 amount) public {
        vm.assume(solverAddr != address(0));
        vm.assume(amount > 0 && amount < type(uint128).max);

        vm.prank(authorizedCaller);
        ledger.register(orderId, solverAddr, amount);

        assertTrue(ledger.isPending(orderId));
        (address s, uint256 a) = ledger.getPendingFill(orderId);
        assertEq(s, solverAddr);
        assertEq(a, amount);
    }
}
