// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {BalanceLedger} from "../../src/core/BalanceLedger.sol";
import {CollateralRegistry} from "../../src/core/CollateralRegistry.sol";
import {IBalanceLedger} from "../../src/interfaces/IBalanceLedger.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @title FlowE_RWAAttestation
/// @notice Integration test for Flow E: RWA Attestation Deposit (Section 12.5)
///         SpokeVaultRWA deposit → LZ attestation → CollateralRegistry → BalanceLedger
contract FlowE_RWAAttestationTest is Test {
    BalanceLedger public ledger;
    CollateralRegistry public collateralReg;

    address public owner = address(0x1);
    address public lzReceiver = address(0x2);
    address public user1 = address(0x10);
    address public ousg = address(0x200);

    uint256 public constant ETH_CHAIN_ID = 1;

    function setUp() public {
        ledger = BalanceLedger(address(new TransparentUpgradeableProxy(
            address(new BalanceLedger()), owner,
            abi.encodeCall(BalanceLedger.initialize, (owner))
        )));

        collateralReg = CollateralRegistry(address(new TransparentUpgradeableProxy(
            address(new CollateralRegistry()), owner,
            abi.encodeCall(CollateralRegistry.initialize, (owner, address(ledger)))
        )));

        vm.warp(1000);
        vm.startPrank(owner);
        collateralReg.setLayerZeroReceiver(lzReceiver);
        ledger.proposeAuthorizedWriter(address(collateralReg), true);
        vm.warp(1000 + 48 hours + 1);
        ledger.applyAuthorizedWriter();
        vm.stopPrank();
    }

    /// @notice Full Flow E: OUSG deposited on Ethereum → attestation via LZ → CollateralRegistry → BalanceLedger
    function test_flowE_rwa_attestation_e2e() public {
        // STEP 1: User deposits OUSG on Ethereum (simulated by SpokeVaultRWA)
        // SpokeVaultRWA constructs AttestationMessage and sends via LayerZero

        // STEP 2: LayerZero delivers attestation to CollateralRegistry on Arbitrum
        bytes32 attestationId = keccak256(abi.encode(user1, ousg, 100e18, 1));

        vm.prank(lzReceiver);
        collateralReg.processAttestation(
            attestationId,
            user1,
            ousg,
            100e18,        // 100 OUSG
            block.timestamp,
            ETH_CHAIN_ID
        );

        // STEP 3: Verify collateral position created in BalanceLedger
        IBalanceLedger.CollateralPosition[] memory positions = ledger.getCollateral(user1);
        assertEq(positions.length, 1);
        assertEq(positions[0].asset, ousg);
        assertEq(positions[0].amount, 100e18);
        assertEq(positions[0].sourceChainId, ETH_CHAIN_ID);
        assertTrue(positions[0].state == IBalanceLedger.CollateralState.ACTIVE);

        // STEP 4: isUsedAsCollateral auto-enabled
        assertTrue(ledger.getIsUsedAsCollateral(user1, ousg));

        // STEP 5: Attestation recorded (replay prevented)
        assertTrue(collateralReg.isAttestationUsed(attestationId));
        assertEq(collateralReg.getLastAttestationTs(user1, ousg, ETH_CHAIN_ID), block.timestamp);

        // STEP 6: Subsequent deposit accumulates
        bytes32 attestationId2 = keccak256(abi.encode(user1, ousg, 50e18, 2));
        vm.warp(block.timestamp + 1); // advance time for monotonic check

        vm.prank(lzReceiver);
        collateralReg.processAttestation(
            attestationId2,
            user1,
            ousg,
            50e18,
            block.timestamp,
            ETH_CHAIN_ID
        );

        positions = ledger.getCollateral(user1);
        assertEq(positions[0].amount, 150e18); // accumulated
    }
}
