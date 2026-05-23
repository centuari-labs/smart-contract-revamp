// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {DeployTimeLock} from "../../script/timelock/DeployTimeLock.s.sol";

/// @title DeployTimeLockTest
/// @notice Unit tests for the DeployTimeLock script — verifies role assignments and delay
///         configuration match the intended security model for TimeLock-governed upgrades.
contract DeployTimeLockTest is Test {
    // ──────────────────────────────── Constants ───────────────────────────── //

    bytes32 constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 constant CANCELLER_ROLE = keccak256("CANCELLER_ROLE");
    bytes32 constant DEFAULT_ADMIN_ROLE = bytes32(0);

    uint256 constant MAINNET_DELAY = 172_800; // 48 hours
    uint256 constant TESTNET_DELAY = 300; // 5 minutes

    // ─────────────────────────────── Fixtures ────────────────────────────── //

    DeployTimeLock deployScript;
    address multisig;
    address nonParticipant;

    function setUp() public {
        deployScript = new DeployTimeLock();
        multisig = makeAddr("multisig");
        nonParticipant = makeAddr("nonParticipant");
    }

    // ─────────────────────────────── Helpers ─────────────────────────────── //

    function _deploy(uint256 delay, address proposer, address executor) internal returns (TimelockController) {
        return TimelockController(payable(deployScript.deploy(delay, proposer, executor)));
    }

    // ═══════════════════════════════════════════════════════════════════════ //
    //                             Min-delay tests                             //
    // ═══════════════════════════════════════════════════════════════════════ //

    function test_deploy_mainnetDelay_setsMinDelay() public {
        TimelockController tl = _deploy(MAINNET_DELAY, multisig, multisig);
        assertEq(tl.getMinDelay(), MAINNET_DELAY);
    }

    function test_deploy_testnetDelay_setsMinDelay() public {
        TimelockController tl = _deploy(TESTNET_DELAY, multisig, multisig);
        assertEq(tl.getMinDelay(), TESTNET_DELAY);
    }

    function test_deploy_zeroDelay_isAccepted() public {
        // OZ allows zero delay (caller is responsible for choosing a safe value)
        TimelockController tl = _deploy(0, multisig, multisig);
        assertEq(tl.getMinDelay(), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════ //
    //                          Proposer-role tests                            //
    // ═══════════════════════════════════════════════════════════════════════ //

    function test_deploy_proposerHasProposerRole() public {
        TimelockController tl = _deploy(TESTNET_DELAY, multisig, multisig);
        assertTrue(tl.hasRole(PROPOSER_ROLE, multisig));
    }

    function test_deploy_nonProposerDoesNotHaveProposerRole() public {
        TimelockController tl = _deploy(TESTNET_DELAY, multisig, multisig);
        assertFalse(tl.hasRole(PROPOSER_ROLE, nonParticipant));
    }

    // ═══════════════════════════════════════════════════════════════════════ //
    //                          Executor-role tests                            //
    // ═══════════════════════════════════════════════════════════════════════ //

    function test_deploy_executorHasExecutorRole() public {
        TimelockController tl = _deploy(TESTNET_DELAY, multisig, multisig);
        assertTrue(tl.hasRole(EXECUTOR_ROLE, multisig));
    }

    function test_deploy_nonExecutorDoesNotHaveExecutorRole() public {
        TimelockController tl = _deploy(TESTNET_DELAY, multisig, multisig);
        assertFalse(tl.hasRole(EXECUTOR_ROLE, nonParticipant));
    }

    // ═══════════════════════════════════════════════════════════════════════ //
    //                         Canceller-role tests                            //
    //   OZ v5 auto-grants CANCELLER_ROLE to proposers — NOT to executors.    //
    // ═══════════════════════════════════════════════════════════════════════ //

    function test_deploy_proposerHasCancellerRole() public {
        TimelockController tl = _deploy(TESTNET_DELAY, multisig, multisig);
        assertTrue(tl.hasRole(CANCELLER_ROLE, multisig), "OZ v5 auto-grants CANCELLER_ROLE to proposers");
    }

    function test_deploy_differentExecutor_doesNotGetCancellerRole() public {
        address executor = makeAddr("executor");
        TimelockController tl = _deploy(TESTNET_DELAY, multisig, executor);
        assertFalse(tl.hasRole(CANCELLER_ROLE, executor), "CANCELLER_ROLE must NOT be auto-granted to executor");
    }

    function test_deploy_nonParticipantDoesNotHaveCancellerRole() public {
        TimelockController tl = _deploy(TESTNET_DELAY, multisig, multisig);
        assertFalse(tl.hasRole(CANCELLER_ROLE, nonParticipant));
    }

    // ═══════════════════════════════════════════════════════════════════════ //
    //                       Default-admin-role tests                          //
    //  admin=address(0) → OZ grants DEFAULT_ADMIN_ROLE to the TimeLock only. //
    // ═══════════════════════════════════════════════════════════════════════ //

    function test_deploy_timeLockIsSelfAdmin() public {
        TimelockController tl = _deploy(TESTNET_DELAY, multisig, multisig);
        assertTrue(
            tl.hasRole(DEFAULT_ADMIN_ROLE, address(tl)), "TimeLock must hold DEFAULT_ADMIN_ROLE for self-governance"
        );
    }

    function test_deploy_deployerDoesNotHaveAdminRole() public {
        TimelockController tl = _deploy(TESTNET_DELAY, multisig, multisig);
        assertFalse(tl.hasRole(DEFAULT_ADMIN_ROLE, address(this)));
    }

    function test_deploy_multisigDoesNotHaveAdminRole() public {
        // Closed admin: multisig should NOT hold DEFAULT_ADMIN_ROLE — only the TimeLock itself
        TimelockController tl = _deploy(TESTNET_DELAY, multisig, multisig);
        assertFalse(tl.hasRole(DEFAULT_ADMIN_ROLE, multisig));
    }

    function test_deploy_nonParticipantDoesNotHaveAdminRole() public {
        TimelockController tl = _deploy(TESTNET_DELAY, multisig, multisig);
        assertFalse(tl.hasRole(DEFAULT_ADMIN_ROLE, nonParticipant));
    }

    // ═══════════════════════════════════════════════════════════════════════ //
    //                        Split-role edge cases                            //
    // ═══════════════════════════════════════════════════════════════════════ //

    function test_deploy_sameProposerAndExecutor_allRolesOnOneAddress() public {
        TimelockController tl = _deploy(TESTNET_DELAY, multisig, multisig);
        assertTrue(tl.hasRole(PROPOSER_ROLE, multisig));
        assertTrue(tl.hasRole(EXECUTOR_ROLE, multisig));
        assertTrue(tl.hasRole(CANCELLER_ROLE, multisig));
    }

    function test_deploy_differentProposerAndExecutor_rolesAreIsolated() public {
        address executor = makeAddr("executor");
        TimelockController tl = _deploy(TESTNET_DELAY, multisig, executor);

        // Proposer has PROPOSER_ROLE + CANCELLER_ROLE, NOT EXECUTOR_ROLE
        assertTrue(tl.hasRole(PROPOSER_ROLE, multisig));
        assertTrue(tl.hasRole(CANCELLER_ROLE, multisig));
        assertFalse(tl.hasRole(EXECUTOR_ROLE, multisig));

        // Executor has EXECUTOR_ROLE only — NOT PROPOSER or CANCELLER
        assertTrue(tl.hasRole(EXECUTOR_ROLE, executor));
        assertFalse(tl.hasRole(PROPOSER_ROLE, executor));
        assertFalse(tl.hasRole(CANCELLER_ROLE, executor));
    }

    // ═══════════════════════════════════════════════════════════════════════ //
    //                       Initial state machine check                       //
    // ═══════════════════════════════════════════════════════════════════════ //

    function test_deploy_freshTimeLock_arbitraryOperationIsUnset() public {
        TimelockController tl = _deploy(TESTNET_DELAY, multisig, multisig);
        bytes32 randomOp = keccak256("some-operation-that-was-never-scheduled");
        // OperationState.Unset == 0
        assertEq(uint8(tl.getOperationState(randomOp)), 0);
    }
}
