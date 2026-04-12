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
import {HubIntentSettler} from "../../src/core/cross-chain/HubIntentSettler.sol";
import {SettlementLedger} from "../../src/core/cross-chain/SettlementLedger.sol";
import {ISettlementLedger} from "../../src/interfaces/cross-chain/ISettlementLedger.sol";
import {MockToken} from "../../src/mocks/MockToken.sol";

contract SettlementLedgerTest is Test {
    BalanceLedger internal ledger;
    HubIntentSettler internal settler;
    SettlementLedger internal settlementLedger;
    MockToken internal usdc;

    address internal owner = address(0xA11CE);
    address internal operator = address(0x0BEE);
    address internal user = address(0x1111);
    address internal outsider = address(0xDEAD);

    uint256 internal constant SOLVER_MINT = 1_000_000e6;
    uint256 internal constant SOURCE_CHAIN_ID = 8453;

    function setUp() public {
        usdc = new MockToken("USD Coin", "USDC", 6, 0);

        // Deploy BalanceLedger behind proxy
        BalanceLedger ledgerImpl = new BalanceLedger();
        bytes memory ledgerInit = abi.encodeCall(
            BalanceLedger.initialize,
            (owner, true)
        );
        TransparentUpgradeableProxy ledgerProxy = new TransparentUpgradeableProxy(
            address(ledgerImpl),
            address(this),
            ledgerInit
        );
        ledger = BalanceLedger(address(ledgerProxy));

        // Deploy HubIntentSettler behind proxy
        HubIntentSettler settlerImpl = new HubIntentSettler();
        bytes memory settlerInit = abi.encodeCall(
            HubIntentSettler.initialize,
            (owner, operator, address(ledger))
        );
        TransparentUpgradeableProxy settlerProxy = new TransparentUpgradeableProxy(
            address(settlerImpl),
            address(this),
            settlerInit
        );
        settler = HubIntentSettler(address(settlerProxy));

        // Deploy SettlementLedger behind proxy
        SettlementLedger slImpl = new SettlementLedger();
        bytes memory slInit = abi.encodeCall(
            SettlementLedger.initialize,
            (owner, operator, address(settler))
        );
        TransparentUpgradeableProxy slProxy = new TransparentUpgradeableProxy(
            address(slImpl),
            address(this),
            slInit
        );
        settlementLedger = SettlementLedger(address(slProxy));

        // Wire settler ↔ settlementLedger
        vm.prank(owner);
        settler.setSettlementLedger(address(settlementLedger));

        // Register HubIntentSettler as BalanceLedger writer
        vm.prank(owner);
        ledger.forceAddWriter(address(settler));

        // Fund the solver (operator) with tokens
        usdc.mint(operator, SOLVER_MINT);
    }

    // ============ Helpers ============

    function _fillDeposit(
        bytes32 depositId,
        uint256 amount
    ) internal {
        vm.startPrank(operator);
        usdc.approve(address(settler), amount);
        settler.fillFor(depositId, user, address(usdc), amount, SOURCE_CHAIN_ID);
        vm.stopPrank();
    }

    // ============ Initialization ============

    function test_Initialize_SetsState() public view {
        assertEq(settlementLedger.owner(), owner);
        assertEq(settlementLedger.operator(), operator);
        assertEq(settlementLedger.hubIntentSettler(), address(settler));
    }

    function test_Initialize_RevertZeroOwner() public {
        SettlementLedger impl = new SettlementLedger();
        bytes memory badInit = abi.encodeCall(
            SettlementLedger.initialize,
            (address(0), operator, address(settler))
        );
        vm.expectRevert(ISettlementLedger.ZeroAddress.selector);
        new TransparentUpgradeableProxy(address(impl), address(this), badInit);
    }

    function test_Initialize_RevertZeroOperator() public {
        SettlementLedger impl = new SettlementLedger();
        bytes memory badInit = abi.encodeCall(
            SettlementLedger.initialize,
            (owner, address(0), address(settler))
        );
        vm.expectRevert(ISettlementLedger.ZeroAddress.selector);
        new TransparentUpgradeableProxy(address(impl), address(this), badInit);
    }

    function test_Initialize_RevertZeroHubIntentSettler() public {
        SettlementLedger impl = new SettlementLedger();
        bytes memory badInit = abi.encodeCall(
            SettlementLedger.initialize,
            (owner, operator, address(0))
        );
        vm.expectRevert(ISettlementLedger.ZeroAddress.selector);
        new TransparentUpgradeableProxy(address(impl), address(this), badInit);
    }

    // ============ register ============

    function test_Register_StoresRecord() public {
        bytes32 depositId = bytes32(uint256(1));
        uint256 amount = 10_000e6;

        _fillDeposit(depositId, amount);

        ISettlementLedger.ReimbursementRecord memory record = settlementLedger.getRecord(depositId);
        assertEq(record.solver, operator);
        assertEq(record.asset, address(usdc));
        assertEq(record.amount, amount);
        assertEq(
            uint8(record.status),
            uint8(ISettlementLedger.ReimbursementStatus.REGISTERED)
        );
    }

    function test_Register_RevertNotHubIntentSettler() public {
        vm.prank(outsider);
        vm.expectRevert(ISettlementLedger.Unauthorized.selector);
        settlementLedger.register(bytes32(uint256(1)), operator, address(usdc), 1000e6);
    }

    function test_Register_RevertDuplicate() public {
        bytes32 depositId = bytes32(uint256(1));
        _fillDeposit(depositId, 1000e6);

        // Try to register again via a second fillFor → would fail at HubIntentSettler
        // replay check first. Test the SettlementLedger side by calling directly
        // from the hubIntentSettler address.
        vm.prank(address(settler));
        vm.expectRevert(
            abi.encodeWithSelector(
                ISettlementLedger.AlreadyRegistered.selector,
                depositId
            )
        );
        settlementLedger.register(depositId, operator, address(usdc), 1000e6);
    }

    // ============ matchAndReimburse ============

    function test_MatchAndReimburse_ReimbursesSolver() public {
        bytes32 depositId = bytes32(uint256(1));
        uint256 amount = 10_000e6;

        _fillDeposit(depositId, amount);

        uint256 solverBefore = usdc.balanceOf(operator);

        vm.prank(operator);
        settlementLedger.matchAndReimburse(depositId);

        assertEq(usdc.balanceOf(operator), solverBefore + amount);
    }

    function test_MatchAndReimburse_SetsReimbursedStatus() public {
        bytes32 depositId = bytes32(uint256(1));
        _fillDeposit(depositId, 10_000e6);

        vm.prank(operator);
        settlementLedger.matchAndReimburse(depositId);

        ISettlementLedger.ReimbursementRecord memory record = settlementLedger.getRecord(depositId);
        assertEq(
            uint8(record.status),
            uint8(ISettlementLedger.ReimbursementStatus.REIMBURSED)
        );
    }

    function test_MatchAndReimburse_EmitsEvent() public {
        bytes32 depositId = bytes32(uint256(1));
        uint256 amount = 10_000e6;

        _fillDeposit(depositId, amount);

        vm.prank(operator);
        vm.expectEmit(true, true, false, true);
        emit ISettlementLedger.ReimbursementCompleted(
            depositId,
            operator,
            address(usdc),
            amount
        );
        settlementLedger.matchAndReimburse(depositId);
    }

    function test_MatchAndReimburse_RevertNotRegistered() public {
        bytes32 depositId = bytes32(uint256(999));

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISettlementLedger.InvalidStatus.selector,
                depositId,
                ISettlementLedger.ReimbursementStatus.NONE
            )
        );
        settlementLedger.matchAndReimburse(depositId);
    }

    function test_MatchAndReimburse_RevertAlreadyReimbursed() public {
        bytes32 depositId = bytes32(uint256(1));
        _fillDeposit(depositId, 10_000e6);

        vm.prank(operator);
        settlementLedger.matchAndReimburse(depositId);

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISettlementLedger.InvalidStatus.selector,
                depositId,
                ISettlementLedger.ReimbursementStatus.REIMBURSED
            )
        );
        settlementLedger.matchAndReimburse(depositId);
    }

    function test_MatchAndReimburse_RevertNonOperator() public {
        bytes32 depositId = bytes32(uint256(1));
        _fillDeposit(depositId, 10_000e6);

        vm.prank(outsider);
        vm.expectRevert(ISettlementLedger.Unauthorized.selector);
        settlementLedger.matchAndReimburse(depositId);
    }

    // ============ Governance ============

    function test_SetOperator() public {
        address newOperator = address(0xBEEF);

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit ISettlementLedger.OperatorUpdated(operator, newOperator);
        settlementLedger.setOperator(newOperator);

        assertEq(settlementLedger.operator(), newOperator);
    }

    function test_SetOperator_RevertZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(ISettlementLedger.ZeroAddress.selector);
        settlementLedger.setOperator(address(0));
    }

    function test_SetOperator_RevertNonOwner() public {
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(
                OwnableUpgradeable.OwnableUnauthorizedAccount.selector,
                outsider
            )
        );
        settlementLedger.setOperator(address(0xBEEF));
    }

    function test_SetHubIntentSettler() public {
        address newSettler = address(0xBEEF);

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit ISettlementLedger.HubIntentSettlerUpdated(address(settler), newSettler);
        settlementLedger.setHubIntentSettler(newSettler);

        assertEq(settlementLedger.hubIntentSettler(), newSettler);
    }

    function test_SetHubIntentSettler_RevertZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(ISettlementLedger.ZeroAddress.selector);
        settlementLedger.setHubIntentSettler(address(0));
    }

    // ============ Views ============

    function test_GetRecord_DefaultNone() public view {
        ISettlementLedger.ReimbursementRecord memory record = settlementLedger.getRecord(
            bytes32(uint256(999))
        );
        assertEq(record.solver, address(0));
        assertEq(record.asset, address(0));
        assertEq(record.amount, 0);
        assertEq(
            uint8(record.status),
            uint8(ISettlementLedger.ReimbursementStatus.NONE)
        );
    }

    // ============ Fuzz ============

    function testFuzz_FillAndReimburse(uint256 amount) public {
        amount = bound(amount, 1, SOLVER_MINT);
        bytes32 depositId = bytes32(uint256(42));

        _fillDeposit(depositId, amount);

        uint256 solverBefore = usdc.balanceOf(operator);

        vm.prank(operator);
        settlementLedger.matchAndReimburse(depositId);

        assertEq(usdc.balanceOf(operator), solverBefore + amount);
        assertEq(usdc.balanceOf(address(settler)), 0);
    }
}
