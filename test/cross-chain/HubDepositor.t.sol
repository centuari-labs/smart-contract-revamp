// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {BalanceLedger} from "../../src/core/balance-ledger/BalanceLedger.sol";
import {HubDepositor} from "../../src/core/cross-chain/HubDepositor.sol";
import {IHubDepositor} from "../../src/interfaces/cross-chain/IHubDepositor.sol";
import {MockToken} from "../../src/mocks/MockToken.sol";

contract HubDepositorTest is Test {
    BalanceLedger internal ledger;
    HubDepositor internal depositor;
    MockToken internal usdc;

    address internal owner = address(0xA11CE);
    address internal user = address(0x1111);
    address internal outsider = address(0xDEAD);

    uint256 internal constant INITIAL_MINT = 1_000_000e6; // 1M USDC

    function setUp() public {
        // Deploy MockToken (USDC with 6 decimals)
        usdc = new MockToken("USD Coin", "USDC", 6, 0);

        // Deploy BalanceLedger behind a proxy
        BalanceLedger ledgerImpl = new BalanceLedger();
        bytes memory ledgerInit = abi.encodeCall(BalanceLedger.initialize, (owner, true));
        TransparentUpgradeableProxy ledgerProxy = new TransparentUpgradeableProxy(
            address(ledgerImpl),
            address(this),
            ledgerInit
        );
        ledger = BalanceLedger(address(ledgerProxy));

        // Deploy HubDepositor behind a proxy
        HubDepositor depositorImpl = new HubDepositor();
        bytes memory depositorInit = abi.encodeCall(
            HubDepositor.initialize,
            (owner, address(ledger))
        );
        TransparentUpgradeableProxy depositorProxy = new TransparentUpgradeableProxy(
            address(depositorImpl),
            address(this),
            depositorInit
        );
        depositor = HubDepositor(address(depositorProxy));

        // Register HubDepositor as an authorized writer on BalanceLedger
        vm.prank(owner);
        ledger.forceAddWriter(address(depositor));

        // Mint tokens to the user for testing
        usdc.mint(user, INITIAL_MINT);
    }

    // ============ Initialization ============

    function test_Initialize_SetsState() public view {
        assertEq(depositor.owner(), owner);
        assertEq(depositor.balanceLedger(), address(ledger));
    }

    function test_Initialize_RevertZeroOwner() public {
        HubDepositor impl = new HubDepositor();
        bytes memory badInit = abi.encodeCall(
            HubDepositor.initialize,
            (address(0), address(ledger))
        );
        vm.expectRevert(IHubDepositor.ZeroAddress.selector);
        new TransparentUpgradeableProxy(address(impl), address(this), badInit);
    }

    function test_Initialize_RevertZeroBalanceLedger() public {
        HubDepositor impl = new HubDepositor();
        bytes memory badInit = abi.encodeCall(
            HubDepositor.initialize,
            (owner, address(0))
        );
        vm.expectRevert(IHubDepositor.ZeroAddress.selector);
        new TransparentUpgradeableProxy(address(impl), address(this), badInit);
    }

    // ============ Deposit ============

    function test_Deposit_CreditsBalanceLedger() public {
        uint256 depositAmount = 100e6;

        vm.startPrank(user);
        usdc.approve(address(depositor), depositAmount);
        depositor.deposit(address(usdc), depositAmount);
        vm.stopPrank();

        // BalanceLedger should reflect the credit
        assertEq(ledger.available(user, address(usdc)), depositAmount);
    }

    function test_Deposit_PullsTokens() public {
        uint256 depositAmount = 100e6;
        uint256 userBalanceBefore = usdc.balanceOf(user);

        vm.startPrank(user);
        usdc.approve(address(depositor), depositAmount);
        depositor.deposit(address(usdc), depositAmount);
        vm.stopPrank();

        // Tokens should have moved from user to depositor contract
        assertEq(usdc.balanceOf(user), userBalanceBefore - depositAmount);
        assertEq(usdc.balanceOf(address(depositor)), depositAmount);
    }

    function test_Deposit_EmitsEvent() public {
        uint256 depositAmount = 100e6;

        vm.startPrank(user);
        usdc.approve(address(depositor), depositAmount);

        vm.expectEmit(true, true, false, true);
        emit IHubDepositor.Deposited(user, address(usdc), depositAmount);
        depositor.deposit(address(usdc), depositAmount);
        vm.stopPrank();
    }

    function test_Deposit_RevertZeroAmount() public {
        vm.prank(user);
        vm.expectRevert(IHubDepositor.ZeroAmount.selector);
        depositor.deposit(address(usdc), 0);
    }

    function test_Deposit_RevertZeroAsset() public {
        vm.prank(user);
        vm.expectRevert(IHubDepositor.ZeroAddress.selector);
        depositor.deposit(address(0), 100e6);
    }

    function test_Deposit_MultipleDeposits() public {
        uint256 first = 100e6;
        uint256 second = 200e6;

        vm.startPrank(user);
        usdc.approve(address(depositor), first + second);
        depositor.deposit(address(usdc), first);
        depositor.deposit(address(usdc), second);
        vm.stopPrank();

        assertEq(ledger.available(user, address(usdc)), first + second);
        assertEq(usdc.balanceOf(address(depositor)), first + second);
    }

    // ============ Payout ============

    function test_Payout_ReleasesTokens() public {
        uint256 depositAmount = 100e6;
        uint256 payoutAmount = 50e6;

        // First deposit
        vm.startPrank(user);
        usdc.approve(address(depositor), depositAmount);
        depositor.deposit(address(usdc), depositAmount);
        vm.stopPrank();

        uint256 userBalanceAfterDeposit = usdc.balanceOf(user);

        // Payout (owner calls)
        vm.prank(owner);
        depositor.payout(user, address(usdc), payoutAmount);

        // User should receive tokens back
        assertEq(usdc.balanceOf(user), userBalanceAfterDeposit + payoutAmount);
        assertEq(usdc.balanceOf(address(depositor)), depositAmount - payoutAmount);
    }

    function test_Payout_DebitsBalanceLedger() public {
        uint256 depositAmount = 100e6;
        uint256 payoutAmount = 50e6;

        vm.startPrank(user);
        usdc.approve(address(depositor), depositAmount);
        depositor.deposit(address(usdc), depositAmount);
        vm.stopPrank();

        vm.prank(owner);
        depositor.payout(user, address(usdc), payoutAmount);

        assertEq(ledger.available(user, address(usdc)), depositAmount - payoutAmount);
    }

    function test_Payout_EmitsEvent() public {
        uint256 depositAmount = 100e6;
        uint256 payoutAmount = 50e6;

        vm.startPrank(user);
        usdc.approve(address(depositor), depositAmount);
        depositor.deposit(address(usdc), depositAmount);
        vm.stopPrank();

        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit IHubDepositor.PayoutReleased(user, address(usdc), payoutAmount);
        depositor.payout(user, address(usdc), payoutAmount);
    }

    function test_Payout_RevertZeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(IHubDepositor.ZeroAmount.selector);
        depositor.payout(user, address(usdc), 0);
    }

    function test_Payout_RevertZeroUser() public {
        vm.prank(owner);
        vm.expectRevert(IHubDepositor.ZeroAddress.selector);
        depositor.payout(address(0), address(usdc), 100e6);
    }

    function test_Payout_RevertZeroAsset() public {
        vm.prank(owner);
        vm.expectRevert(IHubDepositor.ZeroAddress.selector);
        depositor.payout(user, address(0), 100e6);
    }

    function test_Payout_RevertNonOwner() public {
        uint256 depositAmount = 100e6;

        vm.startPrank(user);
        usdc.approve(address(depositor), depositAmount);
        depositor.deposit(address(usdc), depositAmount);
        vm.stopPrank();

        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(
                OwnableUpgradeable.OwnableUnauthorizedAccount.selector,
                outsider
            )
        );
        depositor.payout(user, address(usdc), depositAmount);
    }

    function test_Payout_RevertInsufficientLedgerBalance() public {
        // User has no balance, payout should revert at BalanceLedger.debit
        vm.prank(owner);
        vm.expectRevert(); // BalanceLedger will revert with InsufficientBalance
        depositor.payout(user, address(usdc), 100e6);
    }

    function test_Payout_FullBalance() public {
        uint256 depositAmount = 100e6;

        vm.startPrank(user);
        usdc.approve(address(depositor), depositAmount);
        depositor.deposit(address(usdc), depositAmount);
        vm.stopPrank();

        vm.prank(owner);
        depositor.payout(user, address(usdc), depositAmount);

        assertEq(ledger.available(user, address(usdc)), 0);
        assertEq(usdc.balanceOf(address(depositor)), 0);
        assertEq(usdc.balanceOf(user), INITIAL_MINT);
    }

    // ============ Fuzz ============

    function testFuzz_DepositAndPayout(uint256 depositAmount, uint256 payoutAmount) public {
        // Bound to reasonable amounts
        depositAmount = bound(depositAmount, 1, INITIAL_MINT);
        payoutAmount = bound(payoutAmount, 1, depositAmount);

        vm.startPrank(user);
        usdc.approve(address(depositor), depositAmount);
        depositor.deposit(address(usdc), depositAmount);
        vm.stopPrank();

        vm.prank(owner);
        depositor.payout(user, address(usdc), payoutAmount);

        // Invariants
        assertEq(ledger.available(user, address(usdc)), depositAmount - payoutAmount);
        assertEq(usdc.balanceOf(address(depositor)), depositAmount - payoutAmount);
        assertEq(usdc.balanceOf(user), INITIAL_MINT - depositAmount + payoutAmount);
    }
}
