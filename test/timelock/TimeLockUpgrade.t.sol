// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Settlement} from "../../src/core/settlement/Settlement.sol";
import {TimeLockUpgradeBase} from "../../script/timelock/TimeLockUpgradeBase.sol";
import {DeployTimeLock} from "../../script/timelock/DeployTimeLock.s.sol";

// ══════════════════════════════════════════════════════════════════════════════
//  Test Helpers
// ══════════════════════════════════════════════════════════════════════════════

/// @dev Exposes internal helpers of TimeLockUpgradeBase for direct assertion.
contract UpgradeBaseHarness is TimeLockUpgradeBase {
    function buildUpgradeCalldata(address proxy, address newImpl, bytes memory initData)
        external
        pure
        returns (bytes memory)
    {
        return _buildUpgradeCalldata(proxy, newImpl, initData);
    }

    function computeOperationId(address target, bytes memory data, bytes32 salt) external pure returns (bytes32) {
        return _computeOperationId(target, data, salt);
    }

    function getMinDelayView(address timeLock) external view returns (uint256) {
        return _getMinDelay(timeLock);
    }

    function buildScheduleCalldata(address proxyAdmin, bytes memory upgradeCalldata, bytes32 salt, uint256 minDelay)
        external
        pure
        returns (bytes memory)
    {
        return _buildScheduleCalldata(proxyAdmin, upgradeCalldata, salt, minDelay);
    }

    function buildExecuteCalldata(address proxyAdmin, bytes memory upgradeCalldata, bytes32 salt)
        external
        pure
        returns (bytes memory)
    {
        return _buildExecuteCalldata(proxyAdmin, upgradeCalldata, salt);
    }
}

/// @dev V2 settlement: adds a reinitializer and a new view — used for initData upgrade tests.
contract SettlementV2 is Settlement {
    uint256 private _v2Version;

    function initializeV2() external reinitializer(2) {
        _v2Version = 2;
    }

    function v2Version() external view returns (uint256) {
        return _v2Version;
    }
}

/// @dev Minimal contract whose single function requires msg.sender == authorized.
///      Used by the arbitrary-call-prevention security test.
contract MockRestricted {
    address public immutable authorized;
    bool public wasCalled;

    constructor(address _authorized) {
        authorized = _authorized;
    }

    function restrictedCall() external {
        require(msg.sender == authorized, "MockRestricted: unauthorized");
        wasCalled = true;
    }
}

// ══════════════════════════════════════════════════════════════════════════════
//  Integration Test Suite
// ══════════════════════════════════════════════════════════════════════════════

/// @title TimeLockUpgradeTest
/// @notice Integration tests for the full TimeLock upgrade lifecycle:
///           schedule → wait → execute / cancel
///         Also verifies helper correctness (operationId, calldata encoding) and
///         security invariants (access control, arbitrary call prevention).
contract TimeLockUpgradeTest is Test {
    // ─────────────────────────── Constants ───────────────────────────────── //

    /// @dev ERC1967 implementation slot (from EIP-1967 spec)
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    /// @dev ERC1967 admin slot — holds ProxyAdmin address in TransparentUpgradeableProxy
    bytes32 constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    bytes32 constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 constant CANCELLER_ROLE = keccak256("CANCELLER_ROLE");

    uint256 constant MIN_DELAY = 300; // 5-minute testnet delay

    // ─────────────────────────── State ───────────────────────────────────── //

    address multisig;
    address settlementOwner;
    address settlementOperator;
    address centuari;
    address nonAuthorized;

    TimelockController timeLock;
    ProxyAdmin proxyAdmin;
    TransparentUpgradeableProxy proxy;
    Settlement settlement; // proxy, cast to Settlement

    Settlement implV1; // original implementation

    UpgradeBaseHarness harness;
    DeployTimeLock deployScript;

    // ─────────────────────────── Setup ───────────────────────────────────── //

    function setUp() public {
        multisig = makeAddr("multisig");
        settlementOwner = makeAddr("owner");
        settlementOperator = makeAddr("operator");
        centuari = makeAddr("centuari");
        nonAuthorized = makeAddr("nonAuthorized");

        // 1. Deploy TimeLock — multisig is the sole proposer/canceller/executor
        deployScript = new DeployTimeLock();
        timeLock = TimelockController(payable(deployScript.deploy(MIN_DELAY, multisig, multisig)));

        // 2. Deploy bare Settlement implementation
        implV1 = new Settlement();

        // 3. Deploy proxy with TimeLock as ProxyAdmin owner
        bytes memory initData = abi.encodeCall(Settlement.initialize, (settlementOwner, settlementOperator, centuari));
        proxy = new TransparentUpgradeableProxy(
            address(implV1),
            address(timeLock), // ProxyAdmin will be owned by TimeLock
            initData
        );

        // 4. Read ProxyAdmin from ERC1967 admin slot
        proxyAdmin = ProxyAdmin(_addr(vm.load(address(proxy), ADMIN_SLOT)));

        // 5. Cast proxy to Settlement
        settlement = Settlement(address(proxy));

        // 6. Deploy harness for helper unit-tests
        harness = new UpgradeBaseHarness();
    }

    // ─────────────────────────── Helpers ─────────────────────────────────── //

    function _addr(bytes32 b) internal pure returns (address) {
        return address(uint160(uint256(b)));
    }

    function _implAddr() internal view returns (address) {
        return _addr(vm.load(address(proxy), IMPL_SLOT));
    }

    /// @dev Encode ProxyAdmin.upgradeAndCall calldata — mirrors _buildUpgradeCalldata.
    function _upgradeCalldata(address _newImpl) internal view returns (bytes memory) {
        return abi.encodeCall(ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(address(proxy)), _newImpl, ""));
    }

    /// @dev Encode upgradeAndCall with initData — for reinitializer tests.
    function _upgradeWithInitCalldata(address _newImpl, bytes memory initData) internal view returns (bytes memory) {
        return abi.encodeCall(
            ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(address(proxy)), _newImpl, initData)
        );
    }

    /// @dev Replicate OZ v5 hashOperation encoding.
    function _operationId(address target, bytes memory data, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encode(target, uint256(0), data, bytes32(0), salt));
    }

    /// @dev Schedule an upgrade via TimeLock, pranked as multisig.
    function _schedule(address newImpl, bytes32 salt) internal returns (bytes32 operationId) {
        bytes memory data = _upgradeCalldata(newImpl);
        operationId = _operationId(address(proxyAdmin), data, salt);
        vm.prank(multisig);
        timeLock.schedule(address(proxyAdmin), 0, data, bytes32(0), salt, MIN_DELAY);
    }

    /// @dev Execute a scheduled upgrade via TimeLock, pranked as multisig.
    function _execute(address newImpl, bytes32 salt) internal {
        bytes memory data = _upgradeCalldata(newImpl);
        vm.prank(multisig);
        timeLock.execute(address(proxyAdmin), 0, data, bytes32(0), salt);
    }

    /// @dev Schedule + warp + execute in one call (happy-path shortcut).
    /// @dev Uses timeLock.getTimestamp(opId) for the warp target — an external call that
    ///      always sees the current warped block.timestamp, not the test-contract's cached
    ///      pre-warp value. This is required for correctness when called multiple times in
    ///      a single test (second call must warp relative to the first call's warped ts).
    function _scheduleAndExecute(address newImpl, bytes32 salt) internal {
        bytes32 opId = _schedule(newImpl, salt);
        vm.warp(timeLock.getTimestamp(opId)); // readyAt = scheduledAt + minDelay
        _execute(newImpl, salt);
    }

    // ══════════════════════════════════════════════════════════════════════ //
    //  1. Setup verification                                                 //
    // ══════════════════════════════════════════════════════════════════════ //

    function test_setup_proxyAdminOwnerIsTimeLock() public {
        assertEq(proxyAdmin.owner(), address(timeLock));
    }

    function test_setup_implSlotPointsToImplV1() public {
        assertEq(_implAddr(), address(implV1));
    }

    function test_setup_settlementInitializedCorrectly() public {
        assertEq(settlement.operator(), settlementOperator);
    }

    function test_setup_timeLockHasCorrectMinDelay() public {
        assertEq(timeLock.getMinDelay(), MIN_DELAY);
    }

    // ══════════════════════════════════════════════════════════════════════ //
    //  2. Access-control protection — can't bypass TimeLock                  //
    // ══════════════════════════════════════════════════════════════════════ //

    function test_revert_directUpgrade_byNonTimeLock_reverts() public {
        Settlement implV2 = new Settlement();
        // Direct call to ProxyAdmin.upgradeAndCall — caller is not the TimeLock
        vm.prank(nonAuthorized);
        vm.expectRevert();
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(implV2), "");
    }

    function test_revert_directUpgrade_byMultisig_reverts() public {
        // Even the multisig (ProxyAdmin.owner via TimeLock) can't call ProxyAdmin directly
        Settlement implV2 = new Settlement();
        vm.prank(multisig);
        vm.expectRevert();
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(implV2), "");
    }

    function test_revert_schedule_byNonProposer_reverts() public {
        Settlement implV2 = new Settlement();
        bytes memory data = _upgradeCalldata(address(implV2));
        bytes32 salt = keccak256("salt1");
        vm.prank(nonAuthorized);
        vm.expectRevert();
        timeLock.schedule(address(proxyAdmin), 0, data, bytes32(0), salt, MIN_DELAY);
    }

    function test_revert_execute_byNonExecutor_reverts() public {
        Settlement implV2 = new Settlement();
        bytes32 salt = keccak256("salt2");
        _schedule(address(implV2), salt);
        vm.warp(block.timestamp + MIN_DELAY);

        bytes memory data = _upgradeCalldata(address(implV2));
        vm.prank(nonAuthorized);
        vm.expectRevert();
        timeLock.execute(address(proxyAdmin), 0, data, bytes32(0), salt);
    }

    // ══════════════════════════════════════════════════════════════════════ //
    //  3. Schedule happy-path                                                //
    // ══════════════════════════════════════════════════════════════════════ //

    function test_schedule_emitsCallScheduled() public {
        Settlement implV2 = new Settlement();
        bytes32 salt = keccak256("salt3");
        bytes memory data = _upgradeCalldata(address(implV2));
        bytes32 expectedOpId = _operationId(address(proxyAdmin), data, salt);

        vm.prank(multisig);
        vm.expectEmit(true, true, false, true);
        emit TimelockController.CallScheduled(expectedOpId, 0, address(proxyAdmin), 0, data, bytes32(0), MIN_DELAY);
        timeLock.schedule(address(proxyAdmin), 0, data, bytes32(0), salt, MIN_DELAY);
    }

    function test_schedule_operationIsWaiting() public {
        Settlement implV2 = new Settlement();
        bytes32 salt = keccak256("salt4");
        bytes32 opId = _schedule(address(implV2), salt);

        // OperationState.Waiting == 1
        assertEq(uint8(timeLock.getOperationState(opId)), 1);
    }

    function test_schedule_operationIsNotReady_beforeDelay() public {
        Settlement implV2 = new Settlement();
        bytes32 salt = keccak256("salt5");
        bytes32 opId = _schedule(address(implV2), salt);

        vm.warp(block.timestamp + MIN_DELAY - 1);
        assertFalse(timeLock.isOperationReady(opId));
    }

    function test_schedule_operationIsReady_afterDelay() public {
        Settlement implV2 = new Settlement();
        bytes32 salt = keccak256("salt6");
        bytes32 opId = _schedule(address(implV2), salt);

        vm.warp(block.timestamp + MIN_DELAY);
        assertTrue(timeLock.isOperationReady(opId));
    }

    // ══════════════════════════════════════════════════════════════════════ //
    //  4. Execute-before-delay error paths                                   //
    // ══════════════════════════════════════════════════════════════════════ //

    function test_revert_execute_beforeDelay_reverts() public {
        Settlement implV2 = new Settlement();
        bytes32 salt = keccak256("salt7");
        _schedule(address(implV2), salt);

        vm.warp(block.timestamp + MIN_DELAY - 1); // one second short
        bytes memory data = _upgradeCalldata(address(implV2));
        vm.prank(multisig);
        vm.expectRevert();
        timeLock.execute(address(proxyAdmin), 0, data, bytes32(0), salt);
    }

    function test_revert_execute_withoutSchedule_reverts() public {
        Settlement implV2 = new Settlement();
        bytes32 salt = keccak256("salt8");
        bytes memory data = _upgradeCalldata(address(implV2));
        vm.prank(multisig);
        vm.expectRevert();
        timeLock.execute(address(proxyAdmin), 0, data, bytes32(0), salt);
    }

    // ══════════════════════════════════════════════════════════════════════ //
    //  5. Execute after delay — happy path                                   //
    // ══════════════════════════════════════════════════════════════════════ //

    function test_execute_afterDelay_updatesImplSlot() public {
        Settlement implV2 = new Settlement();
        _scheduleAndExecute(address(implV2), keccak256("salt9"));

        assertEq(_implAddr(), address(implV2));
    }

    function test_execute_afterDelay_operationIsDone() public {
        Settlement implV2 = new Settlement();
        bytes32 salt = keccak256("salt10");
        bytes32 opId = _schedule(address(implV2), salt);
        vm.warp(block.timestamp + MIN_DELAY);
        _execute(address(implV2), salt);

        // OperationState.Done == 3
        assertEq(uint8(timeLock.getOperationState(opId)), 3);
    }

    function test_execute_emitsCallExecuted() public {
        Settlement implV2 = new Settlement();
        bytes32 salt = keccak256("salt11");
        bytes memory data = _upgradeCalldata(address(implV2));
        bytes32 expectedOpId = _operationId(address(proxyAdmin), data, salt);

        _schedule(address(implV2), salt);
        vm.warp(block.timestamp + MIN_DELAY);

        vm.prank(multisig);
        vm.expectEmit(true, true, false, true);
        emit TimelockController.CallExecuted(expectedOpId, 0, address(proxyAdmin), 0, data);
        timeLock.execute(address(proxyAdmin), 0, data, bytes32(0), salt);
    }

    // ══════════════════════════════════════════════════════════════════════ //
    //  6. Cancel flow                                                        //
    // ══════════════════════════════════════════════════════════════════════ //

    function test_cancel_whileWaiting_operationBecomesUnset() public {
        Settlement implV2 = new Settlement();
        bytes32 salt = keccak256("salt12");
        bytes32 opId = _schedule(address(implV2), salt);

        vm.prank(multisig);
        timeLock.cancel(opId);

        // OperationState.Unset == 0
        assertEq(uint8(timeLock.getOperationState(opId)), 0);
    }

    function test_cancel_preventsExecuteAfterDelay() public {
        Settlement implV2 = new Settlement();
        bytes32 salt = keccak256("salt13");
        bytes32 opId = _schedule(address(implV2), salt);

        vm.prank(multisig);
        timeLock.cancel(opId);

        vm.warp(block.timestamp + MIN_DELAY);

        bytes memory data = _upgradeCalldata(address(implV2));
        vm.prank(multisig);
        vm.expectRevert();
        timeLock.execute(address(proxyAdmin), 0, data, bytes32(0), salt);
    }

    function test_cancel_byNonCanceller_reverts() public {
        Settlement implV2 = new Settlement();
        bytes32 salt = keccak256("salt14");
        bytes32 opId = _schedule(address(implV2), salt);

        vm.prank(nonAuthorized);
        vm.expectRevert();
        timeLock.cancel(opId);
    }

    function test_cancel_afterExecute_reverts() public {
        Settlement implV2 = new Settlement();
        bytes32 salt = keccak256("salt15");
        bytes32 opId = _schedule(address(implV2), salt);
        vm.warp(block.timestamp + MIN_DELAY);
        _execute(address(implV2), salt);

        // Once Done, cancel must revert
        vm.prank(multisig);
        vm.expectRevert();
        timeLock.cancel(opId);
    }

    function test_cancel_emitsCancelled() public {
        Settlement implV2 = new Settlement();
        bytes32 salt = keccak256("salt16");
        bytes32 opId = _schedule(address(implV2), salt);

        vm.prank(multisig);
        vm.expectEmit(true, false, false, false);
        emit TimelockController.Cancelled(opId);
        timeLock.cancel(opId);
    }

    // ══════════════════════════════════════════════════════════════════════ //
    //  7. Storage preservation across upgrade                                //
    // ══════════════════════════════════════════════════════════════════════ //

    function test_storagePreservation_operatorSurvivesUpgrade() public {
        // Verify state before upgrade
        assertEq(settlement.operator(), settlementOperator);

        Settlement implV2 = new Settlement();
        _scheduleAndExecute(address(implV2), keccak256("salt17"));

        // State must be identical after upgrade
        assertEq(settlement.operator(), settlementOperator, "operator must survive upgrade");
    }

    function test_storagePreservation_ownerSurvivesUpgrade() public {
        assertEq(settlement.owner(), settlementOwner);

        Settlement implV2 = new Settlement();
        _scheduleAndExecute(address(implV2), keccak256("salt18"));

        assertEq(settlement.owner(), settlementOwner, "owner must survive upgrade");
    }

    function test_storagePreservation_pauseStateSurvivesUpgrade() public {
        // Pause before upgrade
        vm.prank(settlementOwner);
        settlement.pause();
        assertTrue(settlement.paused());

        Settlement implV2 = new Settlement();
        _scheduleAndExecute(address(implV2), keccak256("salt19"));

        assertTrue(settlement.paused(), "paused state must survive upgrade");
    }

    // ══════════════════════════════════════════════════════════════════════ //
    //  8. Duplicate-salt error path                                          //
    // ══════════════════════════════════════════════════════════════════════ //

    function test_revert_scheduleSameSaltTwice_reverts() public {
        Settlement implV2 = new Settlement();
        bytes32 salt = keccak256("dup-salt");
        _schedule(address(implV2), salt);

        // Scheduling the same operationId again must revert
        bytes memory data = _upgradeCalldata(address(implV2));
        vm.prank(multisig);
        vm.expectRevert();
        timeLock.schedule(address(proxyAdmin), 0, data, bytes32(0), salt, MIN_DELAY);
    }

    function test_scheduleAfterExecute_sameOperationId_reverts() public {
        Settlement implV2 = new Settlement();
        bytes32 salt = keccak256("done-salt");
        _schedule(address(implV2), salt);
        vm.warp(block.timestamp + MIN_DELAY);
        _execute(address(implV2), salt);

        // After Done, the same operation cannot be re-scheduled
        bytes memory data = _upgradeCalldata(address(implV2));
        vm.prank(multisig);
        vm.expectRevert();
        timeLock.schedule(address(proxyAdmin), 0, data, bytes32(0), salt, MIN_DELAY);
    }

    // ══════════════════════════════════════════════════════════════════════ //
    //  9. Upgrade with initData — reinitializer is called                    //
    // ══════════════════════════════════════════════════════════════════════ //

    function test_upgradeWithInitData_reinitializerIsCalled() public {
        SettlementV2 implV2 = new SettlementV2();
        bytes memory initData = abi.encodeCall(SettlementV2.initializeV2, ());

        bytes memory upgradeCalldata = abi.encodeCall(
            ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(address(proxy)), address(implV2), initData)
        );
        bytes32 salt = keccak256("salt-reinit");

        vm.prank(multisig);
        timeLock.schedule(address(proxyAdmin), 0, upgradeCalldata, bytes32(0), salt, MIN_DELAY);
        vm.warp(block.timestamp + MIN_DELAY);
        vm.prank(multisig);
        timeLock.execute(address(proxyAdmin), 0, upgradeCalldata, bytes32(0), salt);

        // Verify reinitializer was called
        assertEq(SettlementV2(address(proxy)).v2Version(), 2, "reinitializer must have been called");
    }

    function test_upgradeWithInitData_storageStillPreserved() public {
        SettlementV2 implV2 = new SettlementV2();
        bytes memory initData = abi.encodeCall(SettlementV2.initializeV2, ());
        bytes memory upgradeCalldata = abi.encodeCall(
            ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(address(proxy)), address(implV2), initData)
        );
        bytes32 salt = keccak256("salt-reinit2");

        vm.prank(multisig);
        timeLock.schedule(address(proxyAdmin), 0, upgradeCalldata, bytes32(0), salt, MIN_DELAY);
        vm.warp(block.timestamp + MIN_DELAY);
        vm.prank(multisig);
        timeLock.execute(address(proxyAdmin), 0, upgradeCalldata, bytes32(0), salt);

        // V1 state must still be intact
        assertEq(settlement.operator(), settlementOperator, "operator must survive upgrade with initData");
        assertEq(settlement.owner(), settlementOwner, "owner must survive upgrade with initData");
    }

    // ══════════════════════════════════════════════════════════════════════ //
    //  10. Security: _computeOperationId matches on-chain hashOperation       //
    // ══════════════════════════════════════════════════════════════════════ //

    function test_computeOperationId_matchesOnChainHashOperation() public {
        Settlement implV2 = new Settlement();
        bytes memory data = _upgradeCalldata(address(implV2));
        bytes32 salt = keccak256("crosscheck-salt");

        bytes32 offChainId = harness.computeOperationId(address(proxyAdmin), data, salt);
        bytes32 onChainId = timeLock.hashOperation(address(proxyAdmin), 0, data, bytes32(0), salt);

        assertEq(offChainId, onChainId, "_computeOperationId must match on-chain hashOperation");
    }

    function test_computeOperationId_withDifferentSalts_produceDifferentIds() public {
        Settlement implV2 = new Settlement();
        bytes memory data = _upgradeCalldata(address(implV2));

        bytes32 id1 = harness.computeOperationId(address(proxyAdmin), data, keccak256("saltA"));
        bytes32 id2 = harness.computeOperationId(address(proxyAdmin), data, keccak256("saltB"));

        assertTrue(id1 != id2, "different salts must produce different operationIds");
    }

    function test_computeOperationId_withDifferentCalldata_produceDifferentIds() public {
        Settlement implA = new Settlement();
        Settlement implB = new Settlement();
        bytes32 salt = keccak256("same-salt");

        bytes memory dataA = _upgradeCalldata(address(implA));
        bytes memory dataB = _upgradeCalldata(address(implB));

        bytes32 idA = harness.computeOperationId(address(proxyAdmin), dataA, salt);
        bytes32 idB = harness.computeOperationId(address(proxyAdmin), dataB, salt);

        assertTrue(idA != idB, "different calldata must produce different operationIds");
    }

    // ══════════════════════════════════════════════════════════════════════ //
    //  11. Security: TimeLockUpgradeBase helpers are consistent              //
    // ══════════════════════════════════════════════════════════════════════ //

    function test_buildUpgradeCalldata_matchesManualEncoding() public {
        Settlement implV2 = new Settlement();
        bytes memory fromHarness = harness.buildUpgradeCalldata(address(proxy), address(implV2), "");
        bytes memory manual = abi.encodeCall(
            ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(address(proxy)), address(implV2), "")
        );
        assertEq(fromHarness, manual, "_buildUpgradeCalldata must match manual abi.encodeCall");
    }

    function test_getMinDelay_returnsTimeLockMinDelay() public {
        assertEq(harness.getMinDelayView(address(timeLock)), MIN_DELAY);
    }

    // ══════════════════════════════════════════════════════════════════════ //
    //  12. Security: TimeLock cannot bypass access controls on other contracts//
    // ══════════════════════════════════════════════════════════════════════ //

    function test_security_arbitraryCallPrevention_timeLockCannotCallRestrictedFunction() public {
        // Deploy a contract whose restrictedCall() only allows multisig — NOT the TimeLock
        MockRestricted restricted = new MockRestricted(multisig);

        bytes memory restrictedData = abi.encodeCall(MockRestricted.restrictedCall, ());
        bytes32 salt = keccak256("arbitrary-call");

        // Multisig schedules an arbitrary call via TimeLock targeting the restricted contract
        vm.prank(multisig);
        timeLock.schedule(address(restricted), 0, restrictedData, bytes32(0), salt, MIN_DELAY);
        vm.warp(block.timestamp + MIN_DELAY);

        // Execute propagates the call: msg.sender = TimeLock != multisig → reverts
        vm.prank(multisig);
        vm.expectRevert("MockRestricted: unauthorized");
        timeLock.execute(address(restricted), 0, restrictedData, bytes32(0), salt);

        assertFalse(restricted.wasCalled(), "restrictedCall must not have been invoked");
    }

    function test_security_proxyAdminUpgradeRejectedByNonOwnerPath() public {
        // Verify TimeLock → ProxyAdmin chain is the only valid upgrade path
        // Any direct call to ProxyAdmin.upgradeAndCall that is NOT from the TimeLock reverts.
        Settlement implV2 = new Settlement();
        vm.prank(multisig);
        vm.expectRevert();
        // Multisig calls proxyAdmin directly — fails because proxyAdmin.owner() == timeLock, not multisig
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(implV2), "");
    }

    // ══════════════════════════════════════════════════════════════════════ //
    //  13. Full state-machine: Unset → Waiting → Ready → Done               //
    // ══════════════════════════════════════════════════════════════════════ //

    function test_stateMachine_unsetToWaitingToReadyToDone() public {
        Settlement implV2 = new Settlement();
        bytes32 salt = keccak256("state-machine");
        bytes memory data = _upgradeCalldata(address(implV2));
        bytes32 opId = _operationId(address(proxyAdmin), data, salt);

        // Unset (0)
        assertEq(uint8(timeLock.getOperationState(opId)), 0);

        // Schedule → Waiting (1)
        vm.prank(multisig);
        timeLock.schedule(address(proxyAdmin), 0, data, bytes32(0), salt, MIN_DELAY);
        assertEq(uint8(timeLock.getOperationState(opId)), 1);

        // Warp → Ready (2)
        vm.warp(block.timestamp + MIN_DELAY);
        assertEq(uint8(timeLock.getOperationState(opId)), 2);

        // Execute → Done (3)
        vm.prank(multisig);
        timeLock.execute(address(proxyAdmin), 0, data, bytes32(0), salt);
        assertEq(uint8(timeLock.getOperationState(opId)), 3);
    }

    function test_stateMachine_unsetToWaitingToCancelled() public {
        Settlement implV2 = new Settlement();
        bytes32 salt = keccak256("state-machine-cancel");
        bytes32 opId = _schedule(address(implV2), salt);

        // Waiting (1)
        assertEq(uint8(timeLock.getOperationState(opId)), 1);

        // Cancel → Unset (0, operationId deleted)
        vm.prank(multisig);
        timeLock.cancel(opId);
        assertEq(uint8(timeLock.getOperationState(opId)), 0);
    }

    // ══════════════════════════════════════════════════════════════════════ //
    //  14. Multiple sequential upgrades work correctly                       //
    // ══════════════════════════════════════════════════════════════════════ //

    function test_multipleUpgrades_eachSaltUnique() public {
        Settlement implV2 = new Settlement();
        Settlement implV3 = new Settlement();

        // First upgrade: V1 → V2
        _scheduleAndExecute(address(implV2), keccak256("upgrade-v2"));
        assertEq(_implAddr(), address(implV2));

        // Second upgrade: V2 → V3 (must use a different salt)
        _scheduleAndExecute(address(implV3), keccak256("upgrade-v3"));
        assertEq(_implAddr(), address(implV3));

        // State still preserved across two upgrades
        assertEq(settlement.operator(), settlementOperator);
    }

    // ══════════════════════════════════════════════════════════════════════ //
    //  15. Safe-submittable calldata — post-handover upgrade path (D1b)       //
    // ══════════════════════════════════════════════════════════════════════ //

    function test_buildScheduleCalldata_matchesManualEncoding() public {
        Settlement implV2 = new Settlement();
        bytes memory upgradeCalldata = _upgradeCalldata(address(implV2));
        bytes32 salt = keccak256("safe-schedule");

        bytes memory fromHarness = harness.buildScheduleCalldata(address(proxyAdmin), upgradeCalldata, salt, MIN_DELAY);
        bytes memory manual = abi.encodeCall(
            TimelockController.schedule, (address(proxyAdmin), 0, upgradeCalldata, bytes32(0), salt, MIN_DELAY)
        );
        assertEq(fromHarness, manual, "_buildScheduleCalldata must match manual abi.encodeCall");
    }

    function test_buildExecuteCalldata_matchesManualEncoding() public {
        Settlement implV2 = new Settlement();
        bytes memory upgradeCalldata = _upgradeCalldata(address(implV2));
        bytes32 salt = keccak256("safe-execute");

        bytes memory fromHarness = harness.buildExecuteCalldata(address(proxyAdmin), upgradeCalldata, salt);
        bytes memory manual =
            abi.encodeCall(TimelockController.execute, (address(proxyAdmin), 0, upgradeCalldata, bytes32(0), salt));
        assertEq(fromHarness, manual, "_buildExecuteCalldata must match manual abi.encodeCall");
    }

    /// @dev The post-handover path: a Safe holding PROPOSER+EXECUTOR relays the *encoded*
    ///      schedule/execute calldata to the TimeLock via execTransaction. This proves the
    ///      bytes emitted by printSchedule/printExecute drive a real upgrade through the
    ///      TimeLock's role gating — using only the calldata, never a single-key script call.
    function test_safeSubmittableCalldata_drivesUpgradeEndToEnd() public {
        Settlement implV2 = new Settlement();
        bytes memory upgradeCalldata = _upgradeCalldata(address(implV2));
        bytes32 salt = keccak256("safe-e2e");
        bytes32 opId = _operationId(address(proxyAdmin), upgradeCalldata, salt);

        // 1. Safe (proposer) relays schedule calldata to the TimeLock.
        bytes memory scheduleCalldata =
            harness.buildScheduleCalldata(address(proxyAdmin), upgradeCalldata, salt, MIN_DELAY);
        vm.prank(multisig);
        (bool okSchedule,) = address(timeLock).call(scheduleCalldata);
        assertTrue(okSchedule, "Safe-relayed schedule calldata must succeed");
        assertEq(uint8(timeLock.getOperationState(opId)), 1, "operation must be Waiting after schedule");

        // 2. Wait out the delay.
        vm.warp(timeLock.getTimestamp(opId));

        // 3. Safe (executor) relays execute calldata to the TimeLock.
        bytes memory executeCalldata = harness.buildExecuteCalldata(address(proxyAdmin), upgradeCalldata, salt);
        vm.prank(multisig);
        (bool okExecute,) = address(timeLock).call(executeCalldata);
        assertTrue(okExecute, "Safe-relayed execute calldata must succeed");

        assertEq(_implAddr(), address(implV2), "impl slot must point to V2 after Safe-driven upgrade");
        assertEq(uint8(timeLock.getOperationState(opId)), 3, "operation must be Done after execute");
    }

    /// @dev The calldata carries no privilege — the Safe's role does. A non-proposer relaying
    ///      the same schedule bytes is rejected by the TimeLock's onlyRole(PROPOSER_ROLE) gate.
    function test_safeSubmittableScheduleCalldata_byNonProposer_reverts() public {
        Settlement implV2 = new Settlement();
        bytes memory upgradeCalldata = _upgradeCalldata(address(implV2));
        bytes32 salt = keccak256("safe-nonproposer");

        bytes memory scheduleCalldata =
            harness.buildScheduleCalldata(address(proxyAdmin), upgradeCalldata, salt, MIN_DELAY);
        vm.prank(nonAuthorized);
        (bool ok,) = address(timeLock).call(scheduleCalldata);
        assertFalse(ok, "schedule calldata relayed by a non-proposer must revert");
    }
}
