// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CollateralRegistry} from "../../src/core/CollateralRegistry.sol";
import {BalanceLedger} from "../../src/core/BalanceLedger.sol";
import {ICollateralRegistry} from "../../src/interfaces/ICollateralRegistry.sol";
import {IBalanceLedger} from "../../src/interfaces/IBalanceLedger.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract CollateralRegistryTest is Test {
    CollateralRegistry public registry;
    BalanceLedger public ledger;

    address public owner = address(0x1);
    address public lzReceiver = address(0x2);
    address public keeper = address(0x3);
    address public user1 = address(0x10);
    address public ousg = address(0x200);
    address public buidl = address(0x300);

    uint256 public constant ETH_CHAIN_ID = 1;
    uint256 public constant BASE_CHAIN_ID = 8453;

    function setUp() public {
        // Deploy BalanceLedger
        ledger = BalanceLedger(address(new TransparentUpgradeableProxy(
            address(new BalanceLedger()), owner,
            abi.encodeCall(BalanceLedger.initialize, (owner))
        )));

        // Deploy CollateralRegistry
        registry = CollateralRegistry(address(new TransparentUpgradeableProxy(
            address(new CollateralRegistry()), owner,
            abi.encodeCall(CollateralRegistry.initialize, (owner, address(ledger)))
        )));

        // Configure
        vm.startPrank(owner);
        registry.setLayerZeroReceiver(lzReceiver);
        registry.setKeeper(keeper, true);
        ledger.setAuthorizedWriter(address(registry), true);
        vm.stopPrank();
    }

    // ============ processAttestation Tests ============

    function test_processAttestation_success() public {
        bytes32 attestationId = keccak256("attest-1");

        vm.prank(lzReceiver);
        registry.processAttestation(attestationId, user1, ousg, 100e18, 1000, ETH_CHAIN_ID);

        // Verify attestation recorded
        assertTrue(registry.isAttestationUsed(attestationId));
        assertEq(registry.getLastAttestationTs(user1, ousg, ETH_CHAIN_ID), 1000);

        // Verify collateral added in BalanceLedger
        IBalanceLedger.CollateralPosition[] memory positions = ledger.getCollateral(user1);
        assertEq(positions.length, 1);
        assertEq(positions[0].asset, ousg);
        assertEq(positions[0].amount, 100e18);
        assertEq(positions[0].sourceChainId, ETH_CHAIN_ID);
    }

    function test_processAttestation_accumulates() public {
        vm.prank(lzReceiver);
        registry.processAttestation(keccak256("attest-1"), user1, ousg, 100e18, 1000, ETH_CHAIN_ID);

        vm.prank(lzReceiver);
        registry.processAttestation(keccak256("attest-2"), user1, ousg, 50e18, 2000, ETH_CHAIN_ID);

        IBalanceLedger.CollateralPosition[] memory positions = ledger.getCollateral(user1);
        assertEq(positions[0].amount, 150e18);
    }

    function test_processAttestation_multiple_assets() public {
        vm.prank(lzReceiver);
        registry.processAttestation(keccak256("attest-1"), user1, ousg, 100e18, 1000, ETH_CHAIN_ID);

        vm.prank(lzReceiver);
        registry.processAttestation(keccak256("attest-2"), user1, buidl, 200e18, 1000, ETH_CHAIN_ID);

        IBalanceLedger.CollateralPosition[] memory positions = ledger.getCollateral(user1);
        assertEq(positions.length, 2);
    }

    // ============ Replay Prevention Tests (Security Invariant #10) ============

    function test_processAttestation_reverts_duplicate_id() public {
        bytes32 attestationId = keccak256("attest-1");

        vm.prank(lzReceiver);
        registry.processAttestation(attestationId, user1, ousg, 100e18, 1000, ETH_CHAIN_ID);

        // Same ID should revert
        vm.prank(lzReceiver);
        vm.expectRevert(abi.encodeWithSelector(ICollateralRegistry.AttestationAlreadyUsed.selector, attestationId));
        registry.processAttestation(attestationId, user1, ousg, 50e18, 2000, ETH_CHAIN_ID);
    }

    function test_processAttestation_reverts_old_timestamp() public {
        vm.prank(lzReceiver);
        registry.processAttestation(keccak256("attest-1"), user1, ousg, 100e18, 2000, ETH_CHAIN_ID);

        // Older timestamp for same (user, asset, chain) should revert
        vm.prank(lzReceiver);
        vm.expectRevert(abi.encodeWithSelector(ICollateralRegistry.AttestationTooOld.selector, 1000, 2000));
        registry.processAttestation(keccak256("attest-2"), user1, ousg, 50e18, 1000, ETH_CHAIN_ID);
    }

    function test_processAttestation_reverts_equal_timestamp() public {
        vm.prank(lzReceiver);
        registry.processAttestation(keccak256("attest-1"), user1, ousg, 100e18, 1000, ETH_CHAIN_ID);

        // Same timestamp should also revert (must be strictly greater)
        vm.prank(lzReceiver);
        vm.expectRevert(abi.encodeWithSelector(ICollateralRegistry.AttestationTooOld.selector, 1000, 1000));
        registry.processAttestation(keccak256("attest-2"), user1, ousg, 50e18, 1000, ETH_CHAIN_ID);
    }

    // ============ Cross-Chain Replay Prevention ============

    function test_processAttestation_different_chains_independent() public {
        // Same asset on different chains should be independent
        vm.prank(lzReceiver);
        registry.processAttestation(keccak256("attest-eth"), user1, ousg, 100e18, 1000, ETH_CHAIN_ID);

        // Different chain with lower timestamp is OK (independent tracking)
        vm.prank(lzReceiver);
        registry.processAttestation(keccak256("attest-base"), user1, ousg, 50e18, 500, BASE_CHAIN_ID);

        assertEq(registry.getLastAttestationTs(user1, ousg, ETH_CHAIN_ID), 1000);
        assertEq(registry.getLastAttestationTs(user1, ousg, BASE_CHAIN_ID), 500);
    }

    // ============ Access Control Tests ============

    function test_processAttestation_reverts_non_lz_receiver() public {
        vm.prank(user1); // not LZ receiver
        vm.expectRevert(ICollateralRegistry.Unauthorized.selector);
        registry.processAttestation(keccak256("attest-1"), user1, ousg, 100e18, 1000, ETH_CHAIN_ID);
    }

    function test_processAttestation_reverts_zero_address() public {
        vm.prank(lzReceiver);
        vm.expectRevert(ICollateralRegistry.ZeroAddress.selector);
        registry.processAttestation(keccak256("attest-1"), address(0), ousg, 100e18, 1000, ETH_CHAIN_ID);
    }

    function test_processAttestation_reverts_zero_amount() public {
        vm.prank(lzReceiver);
        vm.expectRevert(ICollateralRegistry.ZeroAmount.selector);
        registry.processAttestation(keccak256("attest-1"), user1, ousg, 0, 1000, ETH_CHAIN_ID);
    }

    // ============ Keeper Tests ============

    function test_updateCollateralValue_keeper() public {
        vm.prank(keeper);
        registry.updateCollateralValue(user1, ousg, 10_000e18);
        // Just verifies no revert — value update is event-based for now
    }

    function test_updateCollateralValue_reverts_non_keeper() public {
        vm.prank(user1);
        vm.expectRevert(ICollateralRegistry.Unauthorized.selector);
        registry.updateCollateralValue(user1, ousg, 10_000e18);
    }

    // ============ Administrative Tests ============

    function test_setLayerZeroReceiver() public {
        address newReceiver = address(0x999);
        vm.prank(owner);
        registry.setLayerZeroReceiver(newReceiver);

        // Old receiver should no longer work
        vm.prank(lzReceiver);
        vm.expectRevert(ICollateralRegistry.Unauthorized.selector);
        registry.processAttestation(keccak256("attest-1"), user1, ousg, 100e18, 1000, ETH_CHAIN_ID);

        // New receiver should work
        vm.prank(newReceiver);
        registry.processAttestation(keccak256("attest-1"), user1, ousg, 100e18, 1000, ETH_CHAIN_ID);
    }
}
