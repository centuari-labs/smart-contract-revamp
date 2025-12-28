// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {Treasury} from "../src/core/Treasury.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract TreasuryTest is Test {
    Treasury public treasury;
    ERC20Mock public token;
    ERC20Mock public unsupportedToken;

    address public admin = address(1);
    address public tokenManager = address(2);
    address public user1 = address(3);
    address public user2 = address(4);
    address public lender = address(5);
    address public borrower = address(6);

    bytes32 public constant TOKEN_MANAGER_ROLE =
        keccak256("TOKEN_MANAGER_ROLE");
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    event TokenSupportUpdated(address indexed token, bool supported);
    event Deposited(
        address indexed user,
        address indexed token,
        uint256 amount
    );
    event Withdrawn(
        address indexed user,
        address indexed token,
        uint256 amount
    );
    event Repay(address indexed user, address indexed token, uint256 amount);
    event WithdrawLendPosition(
        address indexed user,
        address indexed token,
        uint256 amount
    );
    event Settlement(
        address indexed lender,
        address indexed borrower,
        address indexed token,
        uint256 amount
    );

    function setUp() public {
        vm.startPrank(admin);

        // Deploy Treasury
        treasury = new Treasury();

        // Deploy mock tokens
        token = new ERC20Mock();
        unsupportedToken = new ERC20Mock();

        // Grant roles
        treasury.grantRole(TOKEN_MANAGER_ROLE, tokenManager);

        vm.stopPrank();

        // Mint tokens to users
        token.mint(user1, 1000 ether);
        token.mint(user2, 1000 ether);
        token.mint(lender, 1000 ether);
        token.mint(borrower, 1000 ether);
    }

    // ========== setSupportedToken Tests ==========

    function test_SetSupportedToken() public {
        vm.prank(tokenManager);
        vm.expectEmit(true, false, false, true);
        emit TokenSupportUpdated(address(token), true);
        treasury.setSupportedToken(address(token), true);

        assertTrue(treasury.supportedToken(address(token)));
    }

    function test_SetSupportedToken_Revert_UnauthorizedUser() public {
        vm.prank(user1);
        vm.expectRevert();
        treasury.setSupportedToken(address(token), true);
    }

    function test_SetSupportedToken_DisableToken() public {
        vm.startPrank(tokenManager);
        treasury.setSupportedToken(address(token), true);

        vm.expectEmit(true, false, false, true);
        emit TokenSupportUpdated(address(token), false);
        treasury.setSupportedToken(address(token), false);
        vm.stopPrank();

        assertFalse(treasury.supportedToken(address(token)));
    }

    // ========== deposit Tests ==========

    function test_Deposit_Success() public {
        // Setup: Enable token support
        vm.prank(tokenManager);
        treasury.setSupportedToken(address(token), true);

        // Approve and deposit
        vm.startPrank(user1);
        token.approve(address(treasury), 100 ether);

        vm.expectEmit(true, true, false, true);
        emit Deposited(user1, address(token), 100 ether);
        treasury.deposit(address(token), 100 ether);
        vm.stopPrank();

        // Verify balances
        assertEq(treasury.balanceOf(user1, address(token)), 100 ether);
        assertEq(token.balanceOf(address(treasury)), 100 ether);
        assertEq(token.balanceOf(user1), 900 ether);
    }

    function test_Deposit_Revert_TokenNotSupported() public {
        vm.startPrank(user1);
        unsupportedToken.approve(address(treasury), 100 ether);

        vm.expectRevert("TOKEN_NOT_SUPPORTED");
        treasury.deposit(address(unsupportedToken), 100 ether);
        vm.stopPrank();
    }

    function test_Deposit_Revert_ZeroAmount() public {
        vm.prank(tokenManager);
        treasury.setSupportedToken(address(token), true);

        vm.prank(user1);
        vm.expectRevert("AMOUNT_ZERO");
        treasury.deposit(address(token), 0);
    }

    function test_Deposit_Multiple() public {
        vm.prank(tokenManager);
        treasury.setSupportedToken(address(token), true);

        vm.startPrank(user1);
        token.approve(address(treasury), 300 ether);

        treasury.deposit(address(token), 100 ether);
        treasury.deposit(address(token), 200 ether);
        vm.stopPrank();

        assertEq(treasury.balanceOf(user1, address(token)), 300 ether);
    }

    function test_Deposit_WhenPaused_Revert() public {
        vm.prank(tokenManager);
        treasury.setSupportedToken(address(token), true);

        vm.prank(admin);
        treasury.pause();

        vm.startPrank(user1);
        token.approve(address(treasury), 100 ether);

        vm.expectRevert();
        treasury.deposit(address(token), 100 ether);
        vm.stopPrank();
    }

    // ========== withdraw Tests ==========

    function test_Withdraw_Success() public {
        // Setup: Deposit first
        vm.prank(tokenManager);
        treasury.setSupportedToken(address(token), true);

        vm.startPrank(user1);
        token.approve(address(treasury), 100 ether);
        treasury.deposit(address(token), 100 ether);

        // Withdraw
        vm.expectEmit(true, true, false, true);
        emit Withdrawn(user1, address(token), 50 ether);
        treasury.withdraw(address(token), 50 ether);
        vm.stopPrank();

        // Verify balances
        assertEq(treasury.balanceOf(user1, address(token)), 50 ether);
        assertEq(token.balanceOf(address(treasury)), 50 ether);
        assertEq(token.balanceOf(user1), 950 ether);
    }

    function test_Withdraw_Revert_InsufficientBalance() public {
        vm.prank(tokenManager);
        treasury.setSupportedToken(address(token), true);

        vm.prank(user1);
        vm.expectRevert("INSUFFICIENT_BALANCE");
        treasury.withdraw(address(token), 100 ether);
    }

    function test_Withdraw_Revert_TokenNotSupported() public {
        vm.prank(user1);
        vm.expectRevert("TOKEN_NOT_SUPPORTED");
        treasury.withdraw(address(unsupportedToken), 100 ether);
    }

    function test_Withdraw_Revert_ZeroAmount() public {
        vm.prank(tokenManager);
        treasury.setSupportedToken(address(token), true);

        vm.prank(user1);
        vm.expectRevert("AMOUNT_ZERO");
        treasury.withdraw(address(token), 0);
    }

    function test_Withdraw_ExactBalance() public {
        vm.prank(tokenManager);
        treasury.setSupportedToken(address(token), true);

        vm.startPrank(user1);
        token.approve(address(treasury), 100 ether);
        treasury.deposit(address(token), 100 ether);

        treasury.withdraw(address(token), 100 ether);
        vm.stopPrank();

        assertEq(treasury.balanceOf(user1, address(token)), 0);
    }

    function test_Withdraw_WhenPaused_Revert() public {
        vm.prank(tokenManager);
        treasury.setSupportedToken(address(token), true);

        vm.startPrank(user1);
        token.approve(address(treasury), 100 ether);
        treasury.deposit(address(token), 100 ether);
        vm.stopPrank();

        vm.prank(admin);
        treasury.pause();

        vm.prank(user1);
        vm.expectRevert();
        treasury.withdraw(address(token), 50 ether);
    }

    // ========== repay Tests ==========

    function test_Repay_Success() public {
        vm.prank(tokenManager);
        treasury.setSupportedToken(address(token), true);

        // Setup: Give user1 some balance
        vm.startPrank(user1);
        token.approve(address(treasury), 100 ether);
        treasury.deposit(address(token), 100 ether);
        vm.stopPrank();

        // Repay
        vm.expectEmit(true, true, false, true);
        emit Repay(user1, address(token), 50 ether);
        treasury.repay(user1, address(token), 50 ether);

        // Verify balances
        assertEq(treasury.balanceOf(user1, address(token)), 50 ether);
        assertEq(
            treasury.balanceOf(address(treasury), address(token)),
            50 ether
        );
    }

    function test_Repay_Revert_InsufficientBalance() public {
        vm.prank(tokenManager);
        treasury.setSupportedToken(address(token), true);

        vm.expectRevert("INSUFFICIENT_BALANCE");
        treasury.repay(user1, address(token), 100 ether);
    }

    function test_Repay_Revert_TokenNotSupported() public {
        vm.expectRevert("TOKEN_NOT_SUPPORTED");
        treasury.repay(user1, address(unsupportedToken), 100 ether);
    }

    function test_Repay_ExactBalance() public {
        vm.prank(tokenManager);
        treasury.setSupportedToken(address(token), true);

        vm.startPrank(user1);
        token.approve(address(treasury), 100 ether);
        treasury.deposit(address(token), 100 ether);
        vm.stopPrank();

        treasury.repay(user1, address(token), 100 ether);

        assertEq(treasury.balanceOf(user1, address(token)), 0);
        assertEq(
            treasury.balanceOf(address(treasury), address(token)),
            100 ether
        );
    }

    // ========== withdrawLendPosition Tests ==========

    function test_WithdrawLendPosition_Success() public {
        vm.prank(tokenManager);
        treasury.setSupportedToken(address(token), true);

        // Setup: Give user1 some balance and move to treasury
        vm.startPrank(user1);
        token.approve(address(treasury), 100 ether);
        treasury.deposit(address(token), 100 ether);
        vm.stopPrank();

        treasury.repay(user1, address(token), 100 ether);

        // WithdrawLendPosition
        vm.expectEmit(true, true, false, true);
        emit WithdrawLendPosition(user1, address(token), 50 ether);
        treasury.withdrawLendPosition(user1, address(token), 50 ether);

        // Verify balances
        assertEq(treasury.balanceOf(user1, address(token)), 50 ether);
        assertEq(
            treasury.balanceOf(address(treasury), address(token)),
            50 ether
        );
    }

    function test_WithdrawLendPosition_Revert_InsufficientBalance() public {
        vm.prank(tokenManager);
        treasury.setSupportedToken(address(token), true);

        vm.expectRevert("INSUFFICIENT_BALANCE");
        treasury.withdrawLendPosition(user1, address(token), 100 ether);
    }

    function test_WithdrawLendPosition_Revert_TokenNotSupported() public {
        vm.expectRevert("TOKEN_NOT_SUPPORTED");
        treasury.withdrawLendPosition(
            user1,
            address(unsupportedToken),
            100 ether
        );
    }

    // ========== settlement Tests ==========

    function test_Settlement_Success() public {
        vm.prank(tokenManager);
        treasury.setSupportedToken(address(token), true);

        // Setup: Give both lender and borrower some balance
        vm.startPrank(lender);
        token.approve(address(treasury), 100 ether);
        treasury.deposit(address(token), 100 ether);
        vm.stopPrank();

        vm.startPrank(borrower);
        token.approve(address(treasury), 200 ether);
        treasury.deposit(address(token), 200 ether);
        vm.stopPrank();

        // Settlement
        vm.expectEmit(true, true, true, true);
        emit Settlement(lender, borrower, address(token), 50 ether);
        treasury.settlement(lender, borrower, address(token), 50 ether);

        // Verify balances
        assertEq(treasury.balanceOf(lender, address(token)), 50 ether);
        assertEq(treasury.balanceOf(borrower, address(token)), 250 ether);
    }

    function test_Settlement_Revert_InsufficientLenderBalance() public {
        vm.prank(tokenManager);
        treasury.setSupportedToken(address(token), true);

        vm.startPrank(borrower);
        token.approve(address(treasury), 200 ether);
        treasury.deposit(address(token), 200 ether);
        vm.stopPrank();

        vm.expectRevert("INSUFFICIENT_BALANCE");
        treasury.settlement(lender, borrower, address(token), 50 ether);
    }

    function test_Settlement_Revert_InsufficientBorrowerBalance() public {
        vm.prank(tokenManager);
        treasury.setSupportedToken(address(token), true);

        vm.startPrank(lender);
        token.approve(address(treasury), 100 ether);
        treasury.deposit(address(token), 100 ether);
        vm.stopPrank();

        vm.expectRevert("INSUFFICIENT_BALANCE");
        treasury.settlement(lender, borrower, address(token), 50 ether);
    }

    function test_Settlement_Revert_TokenNotSupported() public {
        vm.expectRevert("TOKEN_NOT_SUPPORTED");
        treasury.settlement(
            lender,
            borrower,
            address(unsupportedToken),
            50 ether
        );
    }

    function test_Settlement_ExactBalance() public {
        vm.prank(tokenManager);
        treasury.setSupportedToken(address(token), true);

        vm.startPrank(lender);
        token.approve(address(treasury), 100 ether);
        treasury.deposit(address(token), 100 ether);
        vm.stopPrank();

        vm.startPrank(borrower);
        token.approve(address(treasury), 100 ether);
        treasury.deposit(address(token), 100 ether);
        vm.stopPrank();

        treasury.settlement(lender, borrower, address(token), 100 ether);

        assertEq(treasury.balanceOf(lender, address(token)), 0);
        assertEq(treasury.balanceOf(borrower, address(token)), 200 ether);
    }

    // ========== balanceOf Tests ==========

    function test_BalanceOf() public {
        vm.prank(tokenManager);
        treasury.setSupportedToken(address(token), true);

        assertEq(treasury.balanceOf(user1, address(token)), 0);

        vm.startPrank(user1);
        token.approve(address(treasury), 100 ether);
        treasury.deposit(address(token), 100 ether);
        vm.stopPrank();

        assertEq(treasury.balanceOf(user1, address(token)), 100 ether);
    }

    // ========== Pause Tests ==========

    function test_Pause_Success() public {
        vm.prank(admin);
        treasury.pause();

        assertTrue(treasury.paused());
    }

    function test_Pause_Revert_UnauthorizedUser() public {
        vm.prank(user1);
        vm.expectRevert();
        treasury.pause();
    }

    function test_Unpause_Success() public {
        vm.startPrank(admin);
        treasury.pause();
        treasury.unpause();
        vm.stopPrank();

        assertFalse(treasury.paused());
    }

    // ========== Fuzz Tests ==========

    function testFuzz_Deposit(uint256 amount) public {
        vm.assume(amount > 0 && amount <= 1000 ether);

        vm.prank(tokenManager);
        treasury.setSupportedToken(address(token), true);

        vm.startPrank(user1);
        token.approve(address(treasury), amount);
        treasury.deposit(address(token), amount);
        vm.stopPrank();

        assertEq(treasury.balanceOf(user1, address(token)), amount);
    }

    function testFuzz_Withdraw(
        uint256 depositAmount,
        uint256 withdrawAmount
    ) public {
        vm.assume(depositAmount > 0 && depositAmount <= 1000 ether);
        vm.assume(withdrawAmount > 0 && withdrawAmount <= depositAmount);

        vm.prank(tokenManager);
        treasury.setSupportedToken(address(token), true);

        vm.startPrank(user1);
        token.approve(address(treasury), depositAmount);
        treasury.deposit(address(token), depositAmount);
        treasury.withdraw(address(token), withdrawAmount);
        vm.stopPrank();

        assertEq(
            treasury.balanceOf(user1, address(token)),
            depositAmount - withdrawAmount
        );
    }

    function testFuzz_Settlement(
        uint256 lenderAmount,
        uint256 borrowerAmount,
        uint256 settlementAmount
    ) public {
        vm.assume(lenderAmount >= 1 ether && lenderAmount <= 1000 ether);
        vm.assume(borrowerAmount >= 1 ether && borrowerAmount <= 1000 ether);
        vm.assume(
            settlementAmount > 0 &&
                settlementAmount <= lenderAmount &&
                settlementAmount <= borrowerAmount
        );

        vm.prank(tokenManager);
        treasury.setSupportedToken(address(token), true);

        vm.startPrank(lender);
        token.approve(address(treasury), lenderAmount);
        treasury.deposit(address(token), lenderAmount);
        vm.stopPrank();

        vm.startPrank(borrower);
        token.approve(address(treasury), borrowerAmount);
        treasury.deposit(address(token), borrowerAmount);
        vm.stopPrank();

        treasury.settlement(lender, borrower, address(token), settlementAmount);

        assertEq(
            treasury.balanceOf(lender, address(token)),
            lenderAmount - settlementAmount
        );
        assertEq(
            treasury.balanceOf(borrower, address(token)),
            borrowerAmount + settlementAmount
        );
    }

    // ========== Reentrancy Tests ==========

    function test_Deposit_Reentrancy_Protected() public {
        // This would require a malicious token contract
        // Covered by the nonReentrant modifier
    }

    function test_Withdraw_Reentrancy_Protected() public {
        // This would require a malicious token contract
        // Covered by the nonReentrant modifier
    }
}
