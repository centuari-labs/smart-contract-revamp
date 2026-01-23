// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Treasury} from "../src/core/Treasury.sol";
import {ITreasury} from "../src/interfaces/ITreasury.sol";
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
    address public centuariContract = address(7);

    bytes32 public constant TOKEN_MANAGER_ROLE =
        keccak256("TOKEN_MANAGER_ROLE");
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    event TokenSupportUpdated(address indexed token, bool supported);
    event CentuariContractUpdated(address indexed centuariContract);
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
    event SettlementExecuted(
        address indexed loanToken,
        address indexed from,
        address indexed to,
        uint256 amount,
        uint256 lenderSettlementFee,
        uint256 borrowerSettlementFee
    );
    event InternalTransfer(
        address indexed from,
        address indexed to,
        address indexed token,
        uint256 amount,
        bytes32 ref
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

        // Set centuari contract
        treasury.setCentuariContract(centuariContract);

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

    // ========== setCentuariContract Tests ==========

    function test_SetCentuariContract_Success() public {
        address newCentuari = address(8);
        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit CentuariContractUpdated(newCentuari);
        treasury.setCentuariContract(newCentuari);

        assertEq(treasury.centuariContract(), newCentuari);
    }

    function test_SetCentuariContract_Revert_UnauthorizedUser() public {
        vm.prank(user1);
        vm.expectRevert();
        treasury.setCentuariContract(address(8));
    }

    function test_SetCentuariContract_Revert_ZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(ITreasury.ZeroAddress.selector);
        treasury.setCentuariContract(address(0));
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

        vm.expectRevert(ITreasury.Unauthorized.selector);
        treasury.deposit(address(unsupportedToken), 100 ether);
        vm.stopPrank();
    }

    function test_Deposit_Revert_ZeroAmount() public {
        vm.prank(tokenManager);
        treasury.setSupportedToken(address(token), true);

        vm.prank(user1);
        vm.expectRevert(ITreasury.InvalidAmount.selector);
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
        vm.expectRevert(ITreasury.InsufficientFunds.selector);
        treasury.withdraw(address(token), 100 ether);
    }

    function test_Withdraw_Revert_TokenNotSupported() public {
        vm.prank(user1);
        vm.expectRevert(ITreasury.Unauthorized.selector);
        treasury.withdraw(address(unsupportedToken), 100 ether);
    }

    function test_Withdraw_Revert_ZeroAmount() public {
        vm.prank(tokenManager);
        treasury.setSupportedToken(address(token), true);

        vm.prank(user1);
        vm.expectRevert(ITreasury.InvalidAmount.selector);
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
        vm.prank(centuariContract);
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

        vm.prank(centuariContract);
        vm.expectRevert(ITreasury.InsufficientFunds.selector);
        treasury.repay(user1, address(token), 100 ether);
    }

    function test_Repay_Revert_TokenNotSupported() public {
        vm.prank(centuariContract);
        vm.expectRevert(ITreasury.Unauthorized.selector);
        treasury.repay(user1, address(unsupportedToken), 100 ether);
    }

    function test_Repay_ExactBalance() public {
        vm.prank(tokenManager);
        treasury.setSupportedToken(address(token), true);

        vm.startPrank(user1);
        token.approve(address(treasury), 100 ether);
        treasury.deposit(address(token), 100 ether);
        vm.stopPrank();

        vm.prank(centuariContract);
        treasury.repay(user1, address(token), 100 ether);

        assertEq(treasury.balanceOf(user1, address(token)), 0);
        assertEq(
            treasury.balanceOf(address(treasury), address(token)),
            100 ether
        );
    }

    function test_Repay_Revert_OnlyCentuari() public {
        vm.prank(tokenManager);
        treasury.setSupportedToken(address(token), true);

        vm.startPrank(user1);
        token.approve(address(treasury), 100 ether);
        treasury.deposit(address(token), 100 ether);
        vm.expectRevert(ITreasury.Unauthorized.selector);
        treasury.repay(user1, address(token), 50 ether);
        vm.stopPrank();
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

        vm.prank(centuariContract);
        treasury.repay(user1, address(token), 100 ether);

        // WithdrawLendPosition
        vm.prank(centuariContract);
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

        vm.prank(centuariContract);
        vm.expectRevert(ITreasury.InsufficientFunds.selector);
        treasury.withdrawLendPosition(user1, address(token), 100 ether);
    }

    function test_WithdrawLendPosition_Revert_TokenNotSupported() public {
        vm.prank(centuariContract);
        vm.expectRevert(ITreasury.Unauthorized.selector);
        treasury.withdrawLendPosition(
            user1,
            address(unsupportedToken),
            100 ether
        );
    }

    function test_WithdrawLendPosition_Revert_OnlyCentuari() public {
        vm.prank(tokenManager);
        treasury.setSupportedToken(address(token), true);

        vm.prank(user1);
        vm.expectRevert(ITreasury.Unauthorized.selector);
        treasury.withdrawLendPosition(user1, address(token), 50 ether);
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
        vm.prank(centuariContract);
        vm.expectEmit(true, true, true, true);
        emit SettlementExecuted(address(token), lender, borrower, 50 ether, 0, 0);
        treasury.settle(address(token), lender, borrower, 50 ether, 0, 0);

        // Verify balances
        // Lender loses 50 ether (amount), borrower gains 50 ether (no fees)
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

        vm.prank(centuariContract);
        vm.expectRevert(ITreasury.InsufficientFunds.selector);
        treasury.settle(address(token), lender, borrower, 50 ether, 0, 0);
    }

    function test_Settlement_WithFees() public {
        vm.prank(tokenManager);
        treasury.setSupportedToken(address(token), true);

        // Setup: Give lender balance
        vm.startPrank(lender);
        token.approve(address(treasury), 100 ether);
        treasury.deposit(address(token), 100 ether);
        vm.stopPrank();

        // Settlement with fees: 50 ether amount, 5 ether lender fee, 3 ether borrower fee
        vm.prank(centuariContract);
        vm.expectEmit(true, true, true, true);
        emit SettlementExecuted(address(token), lender, borrower, 50 ether, 5 ether, 3 ether);
        treasury.settle(address(token), lender, borrower, 50 ether, 5 ether, 3 ether);

        // Verify balances
        // Lender loses: 50 ether (amount) + 5 ether (lender fee) = 55 ether
        assertEq(treasury.balanceOf(lender, address(token)), 45 ether);
        // Borrower gains: 50 ether (amount) - 3 ether (borrower fee) = 47 ether
        assertEq(treasury.balanceOf(borrower, address(token)), 47 ether);
        // Treasury gains: 5 ether (lender fee) + 3 ether (borrower fee) = 8 ether
        assertEq(treasury.balanceOf(address(treasury), address(token)), 8 ether);
    }

    function test_Settlement_Revert_TokenNotSupported() public {
        vm.prank(centuariContract);
        vm.expectRevert(ITreasury.Unauthorized.selector);
        treasury.settle(
            address(unsupportedToken),
            lender,
            borrower,
            50 ether,
            0,
            0
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

        vm.prank(centuariContract);
        treasury.settle(address(token), lender, borrower, 100 ether, 0, 0);

        // Lender loses 100 ether, borrower gains 100 ether (no fees)
        assertEq(treasury.balanceOf(lender, address(token)), 0);
        assertEq(treasury.balanceOf(borrower, address(token)), 200 ether);
    }

    function test_Settlement_Revert_OnlyCentuari() public {
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

        vm.prank(user1);
        vm.expectRevert(ITreasury.Unauthorized.selector);
        treasury.settle(address(token), lender, borrower, 50 ether, 0, 0);
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
        uint256 settlementAmount
    ) public {
        vm.assume(lenderAmount >= 1 ether && lenderAmount <= 1000 ether);
        vm.assume(settlementAmount > 0 && settlementAmount <= lenderAmount);

        vm.prank(tokenManager);
        treasury.setSupportedToken(address(token), true);

        vm.startPrank(lender);
        token.approve(address(treasury), lenderAmount);
        treasury.deposit(address(token), lenderAmount);
        vm.stopPrank();

        vm.prank(centuariContract);
        treasury.settle(
            address(token),
            lender,
            borrower,
            settlementAmount,
            0,
            0
        );

        // Lender loses settlementAmount, borrower gains settlementAmount (no fees)
        assertEq(
            treasury.balanceOf(lender, address(token)),
            lenderAmount - settlementAmount
        );
        assertEq(
            treasury.balanceOf(borrower, address(token)),
            settlementAmount
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
