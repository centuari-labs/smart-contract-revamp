// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {HubIntentSettler} from "../../src/core/HubIntentSettler.sol";
import {IHubIntentSettler} from "../../src/interfaces/IHubIntentSettler.sol";
import {MockToken} from "../../src/mocks/MockToken.sol";

/// @dev Minimal BalanceLedger stub that records credit calls
contract MockBalanceLedger {
    mapping(address => mapping(address => uint256)) public credited;

    function credit(address user, address asset, uint256 amount) external {
        credited[user][asset] += amount;
    }

    function getAvailable(address user, address asset) external view returns (uint256) {
        return credited[user][asset];
    }

    // Satisfy any debit calls (used by WithdrawalRegistry tests — not needed here but harmless)
    function debit(address user, address asset, uint256 amount) external {
        require(credited[user][asset] >= amount, "insufficient");
        credited[user][asset] -= amount;
    }
}

contract HubIntentSettlerTest is Test {
    HubIntentSettler public settler;
    MockToken public usdc;
    MockBalanceLedger public ledger;

    address public owner = address(0x1);
    address public solver = address(0x10);
    address public user = address(0x20);

    uint256 public constant AMOUNT = 5000e6;

    function setUp() public {
        // HubIntentSettler uses plain Ownable — deploy directly (not via proxy)
        settler = new HubIntentSettler(owner);

        usdc = new MockToken("USD Coin", "USDC", 6, 0);
        ledger = new MockBalanceLedger();

        // Configure settler
        vm.startPrank(owner);
        settler.setBalanceLedger(address(ledger));
        vm.stopPrank();

        // Fund solver with USDC
        usdc.mint(solver, 100_000e6);

        vm.label(address(settler), "HubIntentSettler");
        vm.label(address(usdc), "USDC");
        vm.label(address(ledger), "MockBalanceLedger");
        vm.label(solver, "solver");
        vm.label(user, "user");
    }

    // ── Test: fillFor credits BalanceLedger ───────────────────────────────────

    function test_fillFor_credits_balance() public {
        bytes32 orderId = keccak256("order-1");

        vm.startPrank(solver);
        usdc.approve(address(settler), AMOUNT);
        settler.fillFor(orderId, user, address(usdc), AMOUNT);
        vm.stopPrank();

        assertEq(ledger.credited(user, address(usdc)), AMOUNT);
    }

    // ── Test: fillFor enforces actual token transfer (balanceOf before/after) ─

    function test_fillFor_checks_actual_transfer() public {
        bytes32 orderId = keccak256("order-2");

        uint256 settlerBefore = usdc.balanceOf(address(settler));

        vm.startPrank(solver);
        usdc.approve(address(settler), AMOUNT);
        settler.fillFor(orderId, user, address(usdc), AMOUNT);
        vm.stopPrank();

        // Tokens must have moved to settler (Security Invariant #6)
        assertEq(usdc.balanceOf(address(settler)), settlerBefore + AMOUNT);
    }

    // ── Test: fillFor reverts on zero address user ────────────────────────────

    function test_fillFor_zero_address_reverts() public {
        bytes32 orderId = keccak256("order-3");

        vm.startPrank(solver);
        usdc.approve(address(settler), AMOUNT);
        vm.expectRevert(IHubIntentSettler.ZeroAddress.selector);
        settler.fillFor(orderId, address(0), address(usdc), AMOUNT);
        vm.stopPrank();
    }

    // ── Test: fillFor reverts on zero amount ──────────────────────────────────

    function test_fillFor_zero_amount_reverts() public {
        bytes32 orderId = keccak256("order-4");

        vm.prank(solver);
        vm.expectRevert(IHubIntentSettler.ZeroAmount.selector);
        settler.fillFor(orderId, user, address(usdc), 0);
    }

    // ── Test: fillFor emits SolverFillRegistered event ────────────────────────

    function test_fillFor_emits_event() public {
        bytes32 orderId = keccak256("order-5");

        vm.startPrank(solver);
        usdc.approve(address(settler), AMOUNT);

        vm.expectEmit(true, true, true, true);
        emit IHubIntentSettler.SolverFillRegistered(orderId, solver, user, address(usdc), AMOUNT);
        settler.fillFor(orderId, user, address(usdc), AMOUNT);
        vm.stopPrank();
    }

    // ── Test: setBalanceLedger admin setter ───────────────────────────────────

    function test_setBalanceLedger() public {
        address newLedger = address(0xDEAD);

        vm.prank(owner);
        settler.setBalanceLedger(newLedger);

        assertEq(settler.balanceLedger(), newLedger);
    }

    function test_setBalanceLedger_reverts_non_owner() public {
        vm.prank(solver);
        vm.expectRevert(); // OwnableUnauthorizedAccount
        settler.setBalanceLedger(address(0xDEAD));
    }
}
