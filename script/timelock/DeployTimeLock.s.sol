// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title DeployTimeLock
/// @notice Deploys an OpenZeppelin TimelockController for proxy upgrade governance.
///         Reusable for both hub (Arbitrum) and spoke chains — pass the appropriate
///         minDelay (172800 for mainnet 48h, 300 for testnet 5min).
///
/// @dev Role assignments (OZ v5 behaviour):
///      - proposer       → PROPOSER_ROLE + CANCELLER_ROLE (auto-granted by OZ)
///      - executor       → EXECUTOR_ROLE
///      - admin          → address(0) → ADMIN_ROLE is renounced; only TimeLock self-admin
///
///      The TimelockController itself holds DEFAULT_ADMIN_ROLE (self-admin) so
///      any future minDelay change must be scheduled through the TimeLock itself.
contract DeployTimeLock is Script {
    /// @notice Deploy a TimelockController.
    /// @param minDelay    Minimum delay in seconds before an operation can be executed.
    ///                    Mainnet: 172800 (48 h). Testnet: 300 (5 min).
    /// @param proposer    Address granted PROPOSER_ROLE and CANCELLER_ROLE (e.g. multisig).
    /// @param executor    Address granted EXECUTOR_ROLE (e.g. same multisig — closed execution).
    /// @return timelockAddress The deployed TimelockController address.
    function run(uint256 minDelay, address proposer, address executor) external returns (address timelockAddress) {
        vm.startBroadcast();

        timelockAddress = deploy(minDelay, proposer, executor);

        vm.stopBroadcast();

        console.log("=== TimeLockController Deployment Complete ===");
        console.log("TimeLock address:", timelockAddress);
        console.log("Min delay (seconds):", minDelay);
        console.log("Proposer (PROPOSER_ROLE + CANCELLER_ROLE):", proposer);
        console.log("Executor (EXECUTOR_ROLE):", executor);
        console.log("Admin: renounced (address(0)) - self-admin only");
    }

    /// @notice Core deploy logic (callable by tests and other scripts).
    /// @param minDelay  Minimum delay in seconds.
    /// @param proposer  Address for PROPOSER_ROLE and CANCELLER_ROLE.
    /// @param executor  Address for EXECUTOR_ROLE.
    /// @return timelockAddress The deployed TimelockController address.
    function deploy(uint256 minDelay, address proposer, address executor) public returns (address timelockAddress) {
        address[] memory proposers = new address[](1);
        proposers[0] = proposer;

        address[] memory executors = new address[](1);
        executors[0] = executor;

        // admin = address(0): no external address gets DEFAULT_ADMIN_ROLE.
        // The TimelockController grants DEFAULT_ADMIN_ROLE to itself (self-admin).
        TimelockController timeLock = new TimelockController(minDelay, proposers, executors, address(0));
        timelockAddress = address(timeLock);
    }
}
