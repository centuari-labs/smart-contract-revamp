// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {WithdrawalRegistry} from "../../src/core/WithdrawalRegistry.sol";
import {IWithdrawalRegistry} from "../../src/interfaces/IWithdrawalRegistry.sol";
import {MockToken} from "../../src/mocks/MockToken.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @dev Minimal BalanceLedger stub for WithdrawalRegistry tests
contract MockBalanceLedger {
    mapping(address => mapping(address => uint256)) public balances;

    function setBalance(address user, address asset, uint256 amount) external {
        balances[user][asset] = amount;
    }

    function getAvailable(address user, address asset) external view returns (uint256) {
        return balances[user][asset];
    }

    function debit(address user, address asset, uint256 amount) external {
        require(balances[user][asset] >= amount, "insufficient balance");
        balances[user][asset] -= amount;
    }

    function credit(address user, address asset, uint256 amount) external {
        balances[user][asset] += amount;
    }
}

contract WithdrawalRegistryTest is Test {
    WithdrawalRegistry public registry;
    MockToken public usdc;
    MockBalanceLedger public ledger;

    address public owner = address(0x1);
    address public authorizedCaller = address(0x2);
    address public user = address(0x10);
    address public other = address(0x20);

    uint256 public constant AMOUNT = 1000e6;
    uint256 public constant TARGET_CHAIN_ID = 0; // hub/Arbitrum

    function setUp() public {
        usdc = new MockToken("USD Coin", "USDC", 6, 0);
        ledger = new MockBalanceLedger();

        // Deploy WithdrawalRegistry behind proxy
        registry = WithdrawalRegistry(
            address(
                new TransparentUpgradeableProxy(
                    address(new WithdrawalRegistry()),
                    owner,
                    abi.encodeCall(WithdrawalRegistry.initialize, (owner, address(ledger)))
                )
            )
        );

        // Authorize the test contract and authorizedCaller
        vm.warp(100000);
        vm.startPrank(owner);
        registry.proposeAuthorizedCallerChange(authorizedCaller, true);
        vm.warp(100000 + 48 hours + 1);
        registry.applyAuthorizedCallerChange(authorizedCaller);
        registry.proposeAuthorizedCallerChange(address(this), true);
        vm.warp(100000 + 96 hours + 2);
        registry.applyAuthorizedCallerChange(address(this));
        vm.stopPrank();

        vm.label(address(registry), "WithdrawalRegistry");
        vm.label(address(usdc), "USDC");
        vm.label(address(ledger), "MockBalanceLedger");
        vm.label(user, "user");
        vm.label(other, "other");
    }

    // ── Test: instant path (available >= amount) ──────────────────────────

    function test_requestWithdrawal_instant_path() public {
        // Give user sufficient balance in mock ledger
        ledger.setBalance(user, address(usdc), AMOUNT);

        vm.prank(user);
        bytes32 requestId = registry.requestWithdrawal(address(usdc), AMOUNT, TARGET_CHAIN_ID);

        IWithdrawalRegistry.WithdrawalRequest memory req = registry.getRequest(requestId);

        assertEq(req.user, user);
        assertEq(req.asset, address(usdc));
        assertEq(req.amount, AMOUNT);
        assertEq(req.targetChainId, TARGET_CHAIN_ID);
        assertEq(uint8(req.state), uint8(IWithdrawalRegistry.WithdrawalState.PROCESSING));

        // Debit should have been called — ledger balance is now 0
        assertEq(ledger.getAvailable(user, address(usdc)), 0);
    }

    // ── Test: queued path (available < amount) ────────────────────────────

    function test_requestWithdrawal_queued_path() public {
        // Give user insufficient balance
        ledger.setBalance(user, address(usdc), AMOUNT / 2);

        vm.prank(user);
        bytes32 requestId = registry.requestWithdrawal(address(usdc), AMOUNT, TARGET_CHAIN_ID);

        IWithdrawalRegistry.WithdrawalRequest memory req = registry.getRequest(requestId);

        assertEq(uint8(req.state), uint8(IWithdrawalRegistry.WithdrawalState.PENDING));

        // Debit should NOT have been called — balance unchanged
        assertEq(ledger.getAvailable(user, address(usdc)), AMOUNT / 2);
    }

    // ── Test: zero amount reverts ──────────────────────────────────────────

    function test_requestWithdrawal_zero_amount_reverts() public {
        vm.prank(user);
        vm.expectRevert(IWithdrawalRegistry.ZeroAmount.selector);
        registry.requestWithdrawal(address(usdc), 0, TARGET_CHAIN_ID);
    }

    // ── Test: requestWithdrawal emits event ────────────────────────────────

    function test_requestWithdrawal_emits_event() public {
        ledger.setBalance(user, address(usdc), AMOUNT);

        vm.prank(user);
        vm.expectEmit(false, true, true, true); // skip requestId check (computed on-chain)
        emit IWithdrawalRegistry.WithdrawalRequested(
            bytes32(0), // requestId placeholder — not checked (first bool = false)
            user,
            address(usdc),
            AMOUNT,
            TARGET_CHAIN_ID
        );
        // Use a non-matching emit to avoid the requestId mismatch — check the event fired instead
        // by inspecting state after the call
        registry.requestWithdrawal(address(usdc), AMOUNT, TARGET_CHAIN_ID);
    }

    // ── Test: authorize from authorized caller succeeds ────────────────────

    function test_authorize_from_authorized() public {
        // Create a PENDING request (insufficient balance)
        ledger.setBalance(user, address(usdc), 0);

        vm.prank(user);
        bytes32 requestId = registry.requestWithdrawal(address(usdc), AMOUNT, TARGET_CHAIN_ID);

        // Confirm state is PENDING
        IWithdrawalRegistry.WithdrawalRequest memory req = registry.getRequest(requestId);
        assertEq(uint8(req.state), uint8(IWithdrawalRegistry.WithdrawalState.PENDING));

        // Authorized caller authorizes
        vm.prank(authorizedCaller);
        registry.authorize(requestId);

        req = registry.getRequest(requestId);
        assertEq(uint8(req.state), uint8(IWithdrawalRegistry.WithdrawalState.PROCESSING));
        assertTrue(registry.isAuthorized(requestId));
    }

    // ── Test: authorize from unauthorized reverts ──────────────────────────

    function test_authorize_from_unauthorized_reverts() public {
        ledger.setBalance(user, address(usdc), 0);

        vm.prank(user);
        bytes32 requestId = registry.requestWithdrawal(address(usdc), AMOUNT, TARGET_CHAIN_ID);

        vm.prank(other);
        vm.expectRevert(IWithdrawalRegistry.Unauthorized.selector);
        registry.authorize(requestId);
    }

    // ── Test: complete sets state to COMPLETED ─────────────────────────────

    function test_complete_sets_state() public {
        // Instant path: starts in PROCESSING
        ledger.setBalance(user, address(usdc), AMOUNT);

        vm.prank(user);
        bytes32 requestId = registry.requestWithdrawal(address(usdc), AMOUNT, TARGET_CHAIN_ID);

        IWithdrawalRegistry.WithdrawalRequest memory req = registry.getRequest(requestId);
        assertEq(uint8(req.state), uint8(IWithdrawalRegistry.WithdrawalState.PROCESSING));

        // Complete it
        vm.prank(authorizedCaller);
        registry.complete(requestId);

        req = registry.getRequest(requestId);
        assertEq(uint8(req.state), uint8(IWithdrawalRegistry.WithdrawalState.COMPLETED));
    }

    // ── Test: complete from unauthorized reverts ───────────────────────────

    function test_complete_from_unauthorized_reverts() public {
        ledger.setBalance(user, address(usdc), AMOUNT);

        vm.prank(user);
        bytes32 requestId = registry.requestWithdrawal(address(usdc), AMOUNT, TARGET_CHAIN_ID);

        vm.prank(other);
        vm.expectRevert(IWithdrawalRegistry.Unauthorized.selector);
        registry.complete(requestId);
    }

    // ── Test: escalate after SLA window ────────────────────────────────────

    function test_escalate_after_4h() public {
        ledger.setBalance(user, address(usdc), 0);

        vm.prank(user);
        bytes32 requestId = registry.requestWithdrawal(address(usdc), AMOUNT, TARGET_CHAIN_ID);

        // Warp past the 4-hour SLA window
        vm.warp(block.timestamp + 4 hours + 1);

        // Anyone can escalate
        vm.prank(other);
        registry.escalate(requestId);

        IWithdrawalRegistry.WithdrawalRequest memory req = registry.getRequest(requestId);
        assertEq(uint8(req.state), uint8(IWithdrawalRegistry.WithdrawalState.ESCALATED));
    }

    // ── Test: escalate before SLA window reverts ───────────────────────────

    function test_escalate_before_4h_reverts() public {
        ledger.setBalance(user, address(usdc), 0);

        vm.prank(user);
        bytes32 requestId = registry.requestWithdrawal(address(usdc), AMOUNT, TARGET_CHAIN_ID);

        // Only 2 hours elapsed — below the 4h threshold
        vm.warp(block.timestamp + 2 hours);

        vm.expectRevert(
            abi.encodeWithSelector(
                IWithdrawalRegistry.InvalidState.selector,
                requestId,
                IWithdrawalRegistry.WithdrawalState.PENDING,
                IWithdrawalRegistry.WithdrawalState.ESCALATED
            )
        );
        registry.escalate(requestId);
    }

    // ── Test: MAX_WITHDRAWAL_QUEUE_HOURS constant ──────────────────────────

    function test_MAX_WITHDRAWAL_QUEUE_HOURS() public view {
        assertEq(registry.MAX_WITHDRAWAL_QUEUE_HOURS(), 4);
    }

    // ── Test: setAuthorizedCaller only owner ───────────────────────────────

    function test_proposeAuthorizedCallerChange_only_owner() public {
        vm.prank(other);
        vm.expectRevert(); // OwnableUnauthorizedAccount
        registry.proposeAuthorizedCallerChange(other, true);
    }

    // ── Test: getRequest returns zero struct for unknown requestId ──────────

    function test_getRequest_unknown_returns_empty() public view {
        IWithdrawalRegistry.WithdrawalRequest memory req = registry.getRequest(keccak256("unknown"));
        assertEq(req.user, address(0));
        assertEq(req.amount, 0);
    }
}
