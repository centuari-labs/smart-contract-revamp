// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProtocolTreasury} from "../../src/core/ProtocolTreasury.sol";
import {BalanceLedger} from "../../src/core/BalanceLedger.sol";
import {MockToken} from "../../src/mocks/MockToken.sol";

contract ProtocolTreasuryTest is Test {
    ProtocolTreasury public treasury;
    BalanceLedger public ledger;
    MockToken public token;

    address public owner = address(0x1);
    address public nonOwner = address(0x2);
    address public recipient = address(0x3);

    function setUp() public {
        token = new MockToken("USD Coin", "USDC", 6, 0);

        // Deploy BalanceLedger behind proxy
        vm.warp(1000);
        ledger = BalanceLedger(
            address(
                new TransparentUpgradeableProxy(
                    address(new BalanceLedger()),
                    owner,
                    abi.encodeCall(BalanceLedger.initialize, (owner))
                )
            )
        );

        // Deploy ProtocolTreasury behind proxy
        treasury = ProtocolTreasury(
            address(
                new TransparentUpgradeableProxy(
                    address(new ProtocolTreasury()),
                    owner,
                    abi.encodeCall(ProtocolTreasury.initialize, (owner, address(ledger)))
                )
            )
        );

        // Authorize this test contract as a writer (to credit the treasury)
        vm.startPrank(owner);
        ledger.proposeAuthorizedWriter(address(this), true);
        vm.warp(1000 + 48 hours + 1);
        ledger.applyAuthorizedWriter();
        vm.stopPrank();

        // Fund the ledger contract with real tokens and credit treasury's ledger balance
        uint256 fundAmount = 10_000e6;
        token.mint(address(ledger), fundAmount);
        ledger.credit(address(treasury), address(token), fundAmount);
    }

    // ============ test_receive_funds ============

    function test_receive_funds() public {
        uint256 balanceBefore = ledger.getAvailable(address(treasury), address(token));
        assertEq(balanceBefore, 10_000e6);

        // Credit additional funds
        uint256 additionalAmount = 5_000e6;
        token.mint(address(ledger), additionalAmount);
        ledger.credit(address(treasury), address(token), additionalAmount);

        uint256 balanceAfter = ledger.getAvailable(address(treasury), address(token));
        assertEq(balanceAfter, 15_000e6);
    }

    // ============ test_withdraw_by_owner ============

    function test_withdraw_by_owner() public {
        uint256 withdrawAmount = 3_000e6;
        uint256 recipientBefore = token.balanceOf(recipient);

        vm.prank(owner);
        treasury.withdrawFees(address(token), withdrawAmount, recipient);

        uint256 recipientAfter = token.balanceOf(recipient);
        assertEq(recipientAfter - recipientBefore, withdrawAmount);

        uint256 treasuryLedgerBalance = ledger.getAvailable(address(treasury), address(token));
        assertEq(treasuryLedgerBalance, 10_000e6 - withdrawAmount);
    }

    // ============ test_withdraw_by_non_owner_reverts ============

    function test_withdraw_by_non_owner_reverts() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        treasury.withdrawFees(address(token), 1_000e6, recipient);
    }

    // ============ test_balance_tracking ============

    function test_balance_tracking() public {
        uint256 initialBalance = ledger.getAvailable(address(treasury), address(token));
        assertEq(initialBalance, 10_000e6);

        uint256 firstWithdraw = 2_000e6;
        vm.prank(owner);
        treasury.withdrawFees(address(token), firstWithdraw, recipient);

        uint256 afterFirst = ledger.getAvailable(address(treasury), address(token));
        assertEq(afterFirst, initialBalance - firstWithdraw);

        uint256 secondWithdraw = 3_000e6;
        vm.prank(owner);
        treasury.withdrawFees(address(token), secondWithdraw, recipient);

        uint256 afterSecond = ledger.getAvailable(address(treasury), address(token));
        assertEq(afterSecond, initialBalance - firstWithdraw - secondWithdraw);

        assertEq(token.balanceOf(recipient), firstWithdraw + secondWithdraw);
    }
}
