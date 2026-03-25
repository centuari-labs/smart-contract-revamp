// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SpokeVaultStable} from "../../src/spoke/SpokeVaultStable.sol";
import {ISpokeVaultStable} from "../../src/interfaces/ISpokeVaultStable.sol";
import {MockToken} from "../../src/mocks/MockToken.sol";

contract SpokeVaultStableTest is Test {
    SpokeVaultStable public vault;
    MockToken public token;

    address public owner = address(0x1);
    address public sweeper = address(0x2);
    address public user = address(0x10);
    address public nonSweeper = address(0x20);

    uint256 constant DEPOSIT_AMOUNT = 1_000e6;

    function setUp() public {
        token = new MockToken("USD Coin", "USDC", 6, 0);

        vm.prank(owner);
        vault = new SpokeVaultStable(owner);

        vm.startPrank(owner);
        vault.setSupportedAsset(address(token), true);
        vault.setSweeper(sweeper);
        vm.stopPrank();

        // Fund user
        token.mint(user, 100_000e6);
        vm.prank(user);
        token.approve(address(vault), type(uint256).max);
    }

    // ============ test_deposit_transfers_tokens ============

    function test_deposit_transfers_tokens() public {
        uint256 userBefore = token.balanceOf(user);
        uint256 vaultBefore = token.balanceOf(address(vault));

        vm.expectEmit(true, true, false, true);
        emit ISpokeVaultStable.Deposited(user, address(token), DEPOSIT_AMOUNT);

        vm.prank(user);
        vault.deposit(address(token), DEPOSIT_AMOUNT);

        assertEq(token.balanceOf(user), userBefore - DEPOSIT_AMOUNT);
        assertEq(token.balanceOf(address(vault)), vaultBefore + DEPOSIT_AMOUNT);
        assertEq(vault.getBalance(address(token)), DEPOSIT_AMOUNT);
    }

    // ============ test_deposit_unsupported_asset_reverts ============

    function test_deposit_unsupported_asset_reverts() public {
        MockToken unsupported = new MockToken("Other", "OTH", 18, 0);
        unsupported.mint(user, 1_000e18);
        vm.prank(user);
        unsupported.approve(address(vault), type(uint256).max);

        vm.prank(user);
        vm.expectRevert(ISpokeVaultStable.UnsupportedAsset.selector);
        vault.deposit(address(unsupported), 1_000e18);
    }

    // ============ test_withdraw_onlySweeper ============

    function test_withdraw_onlySweeper() public {
        // Seed vault balance
        vm.prank(user);
        vault.deposit(address(token), DEPOSIT_AMOUNT);

        uint256 sweeperBefore = token.balanceOf(sweeper);

        vm.expectEmit(true, true, false, true);
        emit ISpokeVaultStable.Withdrawn(sweeper, address(token), DEPOSIT_AMOUNT);

        vm.prank(sweeper);
        vault.withdraw(address(token), DEPOSIT_AMOUNT);

        assertEq(token.balanceOf(sweeper), sweeperBefore + DEPOSIT_AMOUNT);
        assertEq(vault.getBalance(address(token)), 0);
    }

    // ============ test_withdraw_non_sweeper_reverts ============

    function test_withdraw_non_sweeper_reverts() public {
        vm.prank(user);
        vault.deposit(address(token), DEPOSIT_AMOUNT);

        vm.prank(nonSweeper);
        vm.expectRevert("SpokeVaultStable: unauthorized");
        vault.withdraw(address(token), DEPOSIT_AMOUNT);
    }

    // ============ test_sweepToHub_reduces_balance ============

    function test_sweepToHub_reduces_balance() public {
        vm.prank(user);
        vault.deposit(address(token), DEPOSIT_AMOUNT);

        uint256 balanceBefore = vault.getBalance(address(token));

        vm.expectEmit(true, false, false, true);
        emit ISpokeVaultStable.SweptToHub(address(token), DEPOSIT_AMOUNT);

        vm.prank(sweeper);
        vault.sweepToHub(address(token), DEPOSIT_AMOUNT, "");

        assertEq(vault.getBalance(address(token)), balanceBefore - DEPOSIT_AMOUNT);
    }

    // ============ test_receiveFromHub_increases_balance ============

    function test_receiveFromHub_increases_balance() public {
        uint256 balanceBefore = vault.getBalance(address(token));
        uint256 receiveAmount = 5_000e6;

        vm.expectEmit(true, false, false, true);
        emit ISpokeVaultStable.ReceivedFromHub(address(token), receiveAmount);

        vm.prank(sweeper);
        vault.receiveFromHub(address(token), receiveAmount);

        assertEq(vault.getBalance(address(token)), balanceBefore + receiveAmount);
    }

    // ============ test_setSupportedAsset ============

    function test_setSupportedAsset() public {
        MockToken newToken = new MockToken("USDT", "USDT", 6, 0);

        // Not supported initially
        newToken.mint(user, 1_000e6);
        vm.prank(user);
        newToken.approve(address(vault), type(uint256).max);

        vm.prank(user);
        vm.expectRevert(ISpokeVaultStable.UnsupportedAsset.selector);
        vault.deposit(address(newToken), 1_000e6);

        // Owner enables it
        vm.prank(owner);
        vault.setSupportedAsset(address(newToken), true);

        // Now deposit succeeds
        vm.prank(user);
        vault.deposit(address(newToken), 1_000e6);
        assertEq(vault.getBalance(address(newToken)), 1_000e6);

        // Owner disables it
        vm.prank(owner);
        vault.setSupportedAsset(address(newToken), false);

        vm.prank(user);
        vm.expectRevert(ISpokeVaultStable.UnsupportedAsset.selector);
        vault.deposit(address(newToken), 1_000e6);
    }

    // ============ Fuzz ============

    function testFuzz_deposit_and_balance(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000e6);
        token.mint(user, amount);
        vm.prank(user);
        token.approve(address(vault), amount);

        vm.prank(user);
        vault.deposit(address(token), amount);

        assertEq(vault.getBalance(address(token)), amount);
    }
}
