// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {BalanceLedger} from "../../src/core/balance-ledger/BalanceLedger.sol";
import {HubIntentSettler} from "../../src/core/cross-chain/HubIntentSettler.sol";
import {SettlementLedger} from "../../src/core/cross-chain/SettlementLedger.sol";
import {IHubIntentSettler} from "../../src/interfaces/cross-chain/IHubIntentSettler.sol";
import {ISettlementLedger} from "../../src/interfaces/cross-chain/ISettlementLedger.sol";
import {MockToken} from "../../src/mocks/MockToken.sol";

contract HubIntentSettlerTest is Test {
    BalanceLedger internal ledger;
    HubIntentSettler internal settler;
    SettlementLedger internal settlementLedger;
    MockToken internal usdc;

    address internal owner = address(0xA11CE);
    address internal operator = address(0x0BEE);
    address internal solver = address(0x5017);
    address internal user = address(0x1111);
    address internal outsider = address(0xDEAD);

    uint256 internal constant SOLVER_MINT = 1_000_000e6;
    uint256 internal constant SOURCE_CHAIN_ID = 8453; // Base

    function setUp() public {
        usdc = new MockToken("USD Coin", "USDC", 6, 0);

        // Deploy BalanceLedger behind proxy
        BalanceLedger ledgerImpl = new BalanceLedger();
        bytes memory ledgerInit = abi.encodeCall(BalanceLedger.initialize, (owner, true));
        TransparentUpgradeableProxy ledgerProxy =
            new TransparentUpgradeableProxy(address(ledgerImpl), address(this), ledgerInit);
        ledger = BalanceLedger(address(ledgerProxy));

        // Deploy HubIntentSettler behind proxy
        HubIntentSettler settlerImpl = new HubIntentSettler();
        bytes memory settlerInit = abi.encodeCall(HubIntentSettler.initialize, (owner, operator, address(ledger)));
        TransparentUpgradeableProxy settlerProxy =
            new TransparentUpgradeableProxy(address(settlerImpl), address(this), settlerInit);
        settler = HubIntentSettler(address(settlerProxy));

        // Deploy SettlementLedger behind proxy
        SettlementLedger slImpl = new SettlementLedger();
        bytes memory slInit = abi.encodeCall(SettlementLedger.initialize, (owner, operator, address(settler)));
        TransparentUpgradeableProxy slProxy = new TransparentUpgradeableProxy(address(slImpl), address(this), slInit);
        settlementLedger = SettlementLedger(address(slProxy));

        // Wire settler → settlementLedger
        vm.prank(owner);
        settler.setSettlementLedger(address(settlementLedger));

        // Register HubIntentSettler as BalanceLedger writer
        vm.prank(owner);
        ledger.forceAddWriter(address(settler));

        // Fund the solver with tokens
        usdc.mint(operator, SOLVER_MINT);
    }

    // ============ Helpers ============

    function _fillFor(bytes32 depositId, uint256 amount) internal {
        vm.startPrank(operator);
        usdc.approve(address(settler), amount);
        settler.fillFor(depositId, user, address(usdc), amount, SOURCE_CHAIN_ID);
        vm.stopPrank();
    }

    // ============ Initialization ============

    function test_Initialize_SetsState() public view {
        assertEq(settler.owner(), owner);
        assertEq(settler.operator(), operator);
        assertEq(settler.balanceLedger(), address(ledger));
        assertEq(settler.settlementLedger(), address(settlementLedger));
        assertFalse(settler.paused());
    }

    function test_Initialize_RevertZeroOwner() public {
        HubIntentSettler impl = new HubIntentSettler();
        bytes memory badInit = abi.encodeCall(HubIntentSettler.initialize, (address(0), operator, address(ledger)));
        vm.expectRevert(IHubIntentSettler.ZeroAddress.selector);
        new TransparentUpgradeableProxy(address(impl), address(this), badInit);
    }

    function test_Initialize_RevertZeroOperator() public {
        HubIntentSettler impl = new HubIntentSettler();
        bytes memory badInit = abi.encodeCall(HubIntentSettler.initialize, (owner, address(0), address(ledger)));
        vm.expectRevert(IHubIntentSettler.ZeroAddress.selector);
        new TransparentUpgradeableProxy(address(impl), address(this), badInit);
    }

    function test_Initialize_RevertZeroBalanceLedger() public {
        HubIntentSettler impl = new HubIntentSettler();
        bytes memory badInit = abi.encodeCall(HubIntentSettler.initialize, (owner, operator, address(0)));
        vm.expectRevert(IHubIntentSettler.ZeroAddress.selector);
        new TransparentUpgradeableProxy(address(impl), address(this), badInit);
    }

    // ============ fillFor ============

    function test_FillFor_TransfersTokensFromSolver() public {
        bytes32 depositId = bytes32(uint256(1));
        uint256 amount = 10_000e6;
        uint256 solverBefore = usdc.balanceOf(operator);

        _fillFor(depositId, amount);

        assertEq(usdc.balanceOf(operator), solverBefore - amount);
        assertEq(usdc.balanceOf(address(settler)), amount);
    }

    function test_FillFor_CreditsUserOnBalanceLedger() public {
        bytes32 depositId = bytes32(uint256(1));
        uint256 amount = 10_000e6;

        _fillFor(depositId, amount);

        assertEq(ledger.available(user, address(usdc)), amount);
    }

    function test_FillFor_RegistersOnSettlementLedger() public {
        bytes32 depositId = bytes32(uint256(1));
        uint256 amount = 10_000e6;

        _fillFor(depositId, amount);

        ISettlementLedger.ReimbursementRecord memory record = settlementLedger.getRecord(depositId);
        assertEq(record.solver, operator);
        assertEq(record.asset, address(usdc));
        assertEq(record.amount, amount);
        assertEq(uint8(record.status), uint8(ISettlementLedger.ReimbursementStatus.REGISTERED));
    }

    function test_FillFor_SetsDepositStatusFilled() public {
        bytes32 depositId = bytes32(uint256(1));
        uint256 amount = 10_000e6;

        _fillFor(depositId, amount);

        assertEq(uint8(settler.depositStatus(depositId)), uint8(IHubIntentSettler.DepositStatus.FILLED));
    }

    function test_FillFor_EmitsEvent() public {
        bytes32 depositId = bytes32(uint256(1));
        uint256 amount = 10_000e6;

        vm.startPrank(operator);
        usdc.approve(address(settler), amount);

        vm.expectEmit(true, true, true, true);
        emit IHubIntentSettler.SolverFillRegistered(depositId, operator, user, address(usdc), amount, SOURCE_CHAIN_ID);
        settler.fillFor(depositId, user, address(usdc), amount, SOURCE_CHAIN_ID);
        vm.stopPrank();
    }

    function test_FillFor_RevertReplay() public {
        bytes32 depositId = bytes32(uint256(1));
        uint256 amount = 10_000e6;

        _fillFor(depositId, amount);

        vm.startPrank(operator);
        usdc.approve(address(settler), amount);
        vm.expectRevert(abi.encodeWithSelector(IHubIntentSettler.DepositAlreadyProcessed.selector, depositId));
        settler.fillFor(depositId, user, address(usdc), amount, SOURCE_CHAIN_ID);
        vm.stopPrank();
    }

    function test_FillFor_RevertZeroUser() public {
        vm.startPrank(operator);
        usdc.approve(address(settler), 1000e6);
        vm.expectRevert(IHubIntentSettler.ZeroAddress.selector);
        settler.fillFor(bytes32(uint256(1)), address(0), address(usdc), 1000e6, SOURCE_CHAIN_ID);
        vm.stopPrank();
    }

    function test_FillFor_RevertZeroAsset() public {
        vm.startPrank(operator);
        vm.expectRevert(IHubIntentSettler.ZeroAddress.selector);
        settler.fillFor(bytes32(uint256(1)), user, address(0), 1000e6, SOURCE_CHAIN_ID);
        vm.stopPrank();
    }

    function test_FillFor_RevertZeroAmount() public {
        vm.startPrank(operator);
        vm.expectRevert(IHubIntentSettler.ZeroAmount.selector);
        settler.fillFor(bytes32(uint256(1)), user, address(usdc), 0, SOURCE_CHAIN_ID);
        vm.stopPrank();
    }

    function test_FillFor_RevertNonOperator() public {
        vm.prank(outsider);
        vm.expectRevert(IHubIntentSettler.Unauthorized.selector);
        settler.fillFor(bytes32(uint256(1)), user, address(usdc), 1000e6, SOURCE_CHAIN_ID);
    }

    function test_FillFor_RevertWhenPaused() public {
        vm.prank(owner);
        settler.pause();

        vm.startPrank(operator);
        usdc.approve(address(settler), 1000e6);
        vm.expectRevert(IHubIntentSettler.ContractPaused.selector);
        settler.fillFor(bytes32(uint256(1)), user, address(usdc), 1000e6, SOURCE_CHAIN_ID);
        vm.stopPrank();
    }

    // ============ markNoFill ============

    function test_MarkNoFill_SetsStatus() public {
        bytes32 depositId = bytes32(uint256(1));

        vm.prank(operator);
        settler.markNoFill(depositId);

        assertEq(uint8(settler.depositStatus(depositId)), uint8(IHubIntentSettler.DepositStatus.NO_FILL));
    }

    function test_MarkNoFill_EmitsEvent() public {
        bytes32 depositId = bytes32(uint256(1));

        vm.prank(operator);
        vm.expectEmit(true, false, false, false);
        emit IHubIntentSettler.DepositMarkedNoFill(depositId);
        settler.markNoFill(depositId);
    }

    function test_MarkNoFill_RevertAlreadyProcessed() public {
        bytes32 depositId = bytes32(uint256(1));

        _fillFor(depositId, 1000e6);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IHubIntentSettler.DepositAlreadyProcessed.selector, depositId));
        settler.markNoFill(depositId);
    }

    function test_MarkNoFill_RevertNonOperator() public {
        vm.prank(outsider);
        vm.expectRevert(IHubIntentSettler.Unauthorized.selector);
        settler.markNoFill(bytes32(uint256(1)));
    }

    // ============ releaseToSolver ============

    function test_ReleaseToSolver_TransfersTokens() public {
        bytes32 depositId = bytes32(uint256(1));
        uint256 amount = 10_000e6;

        _fillFor(depositId, amount);

        uint256 solverBefore = usdc.balanceOf(operator);

        // SettlementLedger calls matchAndReimburse → releaseToSolver
        vm.prank(operator);
        settlementLedger.matchAndReimburse(depositId);

        assertEq(usdc.balanceOf(operator), solverBefore + amount);
        assertEq(usdc.balanceOf(address(settler)), 0);
    }

    function test_ReleaseToSolver_RevertUnauthorized() public {
        vm.prank(outsider);
        vm.expectRevert(IHubIntentSettler.Unauthorized.selector);
        settler.releaseToSolver(solver, address(usdc), 1000e6);
    }

    // ============ Governance ============

    function test_SetOperator() public {
        address newOperator = address(0xBEEF);

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit IHubIntentSettler.OperatorUpdated(operator, newOperator);
        settler.setOperator(newOperator);

        assertEq(settler.operator(), newOperator);
    }

    function test_SetOperator_RevertZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(IHubIntentSettler.ZeroAddress.selector);
        settler.setOperator(address(0));
    }

    function test_SetOperator_RevertNonOwner() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, outsider));
        settler.setOperator(address(0xBEEF));
    }

    function test_SetSettlementLedger() public {
        address newSettlementLedger = address(0xBEEF);

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit IHubIntentSettler.SettlementLedgerUpdated(address(settlementLedger), newSettlementLedger);
        settler.setSettlementLedger(newSettlementLedger);

        assertEq(settler.settlementLedger(), newSettlementLedger);
    }

    function test_SetSettlementLedger_RevertZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(IHubIntentSettler.ZeroAddress.selector);
        settler.setSettlementLedger(address(0));
    }

    function test_Pause_Unpause() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit IHubIntentSettler.Paused(owner);
        settler.pause();
        assertTrue(settler.paused());

        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit IHubIntentSettler.Unpaused(owner);
        settler.unpause();
        assertFalse(settler.paused());
    }

    // ============ Guardian / Pauser (D1) ============

    function test_PauserIsOwnerAtInit() public view {
        assertEq(settler.pauser(), owner);
    }

    function test_SetPauser() public {
        address guardian = makeAddr("guardian");
        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit HubIntentSettler.PauserUpdated(owner, guardian);
        settler.setPauser(guardian);
        assertEq(settler.pauser(), guardian);
    }

    function test_SetPauser_RevertNonOwner() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, outsider));
        settler.setPauser(makeAddr("guardian"));
    }

    function test_SetPauser_RevertZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(IHubIntentSettler.ZeroAddress.selector);
        settler.setPauser(address(0));
    }

    function test_GuardianPausesOwnerCannotAfterRotation() public {
        address guardian = makeAddr("guardian");
        vm.prank(owner);
        settler.setPauser(guardian);

        // owner is no longer the pauser once rotated
        vm.prank(owner);
        vm.expectRevert(IHubIntentSettler.Unauthorized.selector);
        settler.pause();

        // guardian holds the fast pause path
        vm.prank(guardian);
        settler.pause();
        assertTrue(settler.paused());

        vm.prank(guardian);
        settler.unpause();
        assertFalse(settler.paused());
    }

    // ============ Views ============

    function test_DepositStatus_DefaultNone() public view {
        assertEq(uint8(settler.depositStatus(bytes32(uint256(999)))), uint8(IHubIntentSettler.DepositStatus.NONE));
    }

    // ============ Fuzz ============

    function testFuzz_FillFor(uint256 amount) public {
        amount = bound(amount, 1, SOLVER_MINT);
        bytes32 depositId = bytes32(uint256(42));

        _fillFor(depositId, amount);

        assertEq(ledger.available(user, address(usdc)), amount);
        assertEq(usdc.balanceOf(address(settler)), amount);
        assertEq(uint8(settler.depositStatus(depositId)), uint8(IHubIntentSettler.DepositStatus.FILLED));
    }
}
