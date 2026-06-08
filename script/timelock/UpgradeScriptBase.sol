// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {TimeLockUpgradeBase} from "./TimeLockUpgradeBase.sol";

/// @title UpgradeScriptBase
/// @notice Abstract Foundry Script that provides the shared schedule / execute / cancel
///         lifecycle for TimeLock-governed proxy upgrades.
/// @dev Inherits pure/view helpers from TimeLockUpgradeBase and adds vm.* JSON helpers.
///      Concrete upgrade scripts only implement _contractName() and _deployNewImplementation().
///
///      Two upgrade flows, picked by who owns the TimeLock:
///
///      A. EOA path (pre-handover / testnet) — the deployer EOA is proposer+executor:
///        1. runSchedule  — deploys new impl + calls TimeLock.schedule() + writes JSON record
///        2. (wait minDelay seconds on-chain)
///        3. runExecute   — reads JSON record + calls TimeLock.execute()
///        4. runCancel    — reads JSON record + calls TimeLock.cancel() (any time before execute)
///
///      B. Safe path (post-handover / mainnet) — a Gnosis Safe is proposer+executor, so a single
///         `--private-key` broadcast of schedule()/execute() reverts. These emit calldata to
///         submit *through the Safe* (Transaction Builder / SDK / cast) instead of broadcasting:
///        1. printSchedule — deploys new impl (the only broadcast — permissionless) + PRINTS the
///                           TimeLock.schedule() calldata + operationId + salt + writes JSON record
///        2. (submit that calldata through the Safe; wait minDelay)
///        3. printExecute  — reads JSON record + PRINTS the TimeLock.execute() calldata for the Safe
///         Cancellation post-handover is likewise a Safe tx: `TimelockController.cancel(operationId)`
///         (the operationId is printed by printSchedule and stored in the JSON record).
abstract contract UpgradeScriptBase is Script, TimeLockUpgradeBase {
    // ─────────────────────── Abstract Contract Interface ────────────────────── //

    /// @notice Human-readable name used in logs and JSON file names.
    function _contractName() internal pure virtual returns (string memory);

    /// @notice Deploy a fresh implementation contract.
    /// @dev Called inside vm.startBroadcast() — will be broadcast as a real transaction.
    /// @return newImpl Address of the newly deployed implementation.
    function _deployNewImplementation() internal virtual returns (address newImpl);

    // ────────────────────────────── Schedule ───────────────────────────────── //

    /// @notice Deploy a new implementation and schedule the upgrade via TimeLock.
    /// @dev Writes a JSON record to deployments/ for runExecute to consume.
    ///      Salt must be unique per scheduled operation. A good convention is:
    ///        keccak256(abi.encode("<ContractName>", block.timestamp))
    ///      supplied by the operator at call-time.
    /// @param timeLock   TimelockController governing the ProxyAdmin.
    /// @param proxyAdmin ProxyAdmin contract that owns the proxy.
    /// @param proxy      TransparentUpgradeableProxy to upgrade.
    /// @param salt       Unique bytes32 salt for this upgrade operation.
    function runSchedule(address timeLock, address proxyAdmin, address proxy, bytes32 salt) external {
        vm.startBroadcast();

        // 1. Deploy new implementation (concrete contract — differs per upgrade script)
        address newImpl = _deployNewImplementation();

        // 2. Encode ProxyAdmin.upgradeAndCall(proxy, newImpl, "") calldata
        bytes memory upgradeCalldata = _buildUpgradeCalldata(proxy, newImpl, "");

        // 3. Read on-chain minDelay and schedule via TimeLock
        uint256 minDelay = _getMinDelay(timeLock);
        TimelockController(payable(timeLock))
            .schedule(
                proxyAdmin, // target
                0, // value (ETH)
                upgradeCalldata, // data
                bytes32(0), // predecessor (none)
                salt, // unique salt
                minDelay // must be >= TimeLock.getMinDelay()
            );

        vm.stopBroadcast();

        // 4. Compute operationId off-chain (must match on-chain hashOperation)
        bytes32 operationId = _computeOperationId(proxyAdmin, upgradeCalldata, salt);

        // 5. Persist JSON record — runExecute reads this file 48h later
        string memory jsonPath = _writeScheduleRecord(
            _contractName(), operationId, salt, newImpl, proxyAdmin, proxy, block.timestamp, minDelay
        );

        console.log(string.concat("=== ", _contractName(), " Upgrade Scheduled ==="));
        console.log("TimeLock:     ", timeLock);
        console.log("ProxyAdmin:   ", proxyAdmin);
        console.log("Proxy:        ", proxy);
        console.log("New Impl:     ", newImpl);
        console.log("OperationId:  ", vm.toString(operationId));
        console.log("Salt:         ", vm.toString(salt));
        console.log("MinDelay (s): ", minDelay);
        console.log("ReadyAt:      ", block.timestamp + minDelay);
        console.log("Schedule JSON:", jsonPath);
    }

    // ────────────────────────────── Execute ────────────────────────────────── //

    /// @notice Execute a previously scheduled upgrade after the delay has elapsed.
    /// @param timeLock          TimelockController governing the ProxyAdmin.
    /// @param proxyAdmin        ProxyAdmin contract that owns the proxy.
    /// @param proxy             TransparentUpgradeableProxy to upgrade.
    /// @param scheduleJsonPath  Path to the JSON record written by runSchedule.
    function runExecute(address timeLock, address proxyAdmin, address proxy, string memory scheduleJsonPath) external {
        // Read salt and newImpl from the schedule record
        string memory json = vm.readFile(scheduleJsonPath);
        bytes32 salt = vm.parseJsonBytes32(json, ".salt");
        address newImpl = vm.parseJsonAddress(json, ".newImpl");

        // Rebuild calldata identically — must produce the same bytes as runSchedule
        bytes memory upgradeCalldata = _buildUpgradeCalldata(proxy, newImpl, "");

        vm.startBroadcast();

        // TimeLock verifies operationId and that block.timestamp >= scheduledAt + minDelay
        TimelockController(payable(timeLock))
            .execute(
                proxyAdmin, // target
                0, // value (ETH)
                upgradeCalldata, // data (must match schedule)
                bytes32(0), // predecessor (must match schedule)
                salt // salt (must match schedule)
            );

        vm.stopBroadcast();

        console.log(string.concat("=== ", _contractName(), " Upgrade Executed ==="));
        console.log("TimeLock:   ", timeLock);
        console.log("ProxyAdmin: ", proxyAdmin);
        console.log("Proxy:      ", proxy);
        console.log("New Impl:   ", newImpl);
        console.log("Salt:       ", vm.toString(salt));
    }

    // ─────────────────────────────── Cancel ────────────────────────────────── //

    /// @notice Cancel a pending scheduled upgrade (must be called before execution).
    /// @param timeLock          TimelockController governing the ProxyAdmin.
    /// @param scheduleJsonPath  Path to the JSON record written by runSchedule.
    function runCancel(address timeLock, string memory scheduleJsonPath) external {
        string memory json = vm.readFile(scheduleJsonPath);
        bytes32 operationId = vm.parseJsonBytes32(json, ".operationId");

        vm.startBroadcast();
        TimelockController(payable(timeLock)).cancel(operationId);
        vm.stopBroadcast();

        console.log(string.concat("=== ", _contractName(), " Upgrade Cancelled ==="));
        console.log("TimeLock:    ", timeLock);
        console.log("OperationId: ", vm.toString(operationId));
    }

    // ───────────────────── Safe path (post-handover / mainnet) ─────────────────────── //

    /// @notice Deploy the new implementation and PRINT the TimeLock.schedule() calldata to submit
    ///         through the Safe — the post-handover counterpart to runSchedule.
    /// @dev Broadcasts ONLY the implementation deployment (permissionless: needs gas, not a role).
    ///      It does NOT call schedule() — after the handover the proposer is the Safe, not this
    ///      key, so a single-key schedule() would revert. The operator relays the printed calldata
    ///      to the TimeLock through the Safe (`to` = TimeLock, `value` = 0, `data` = printed bytes).
    ///      Writes the same JSON record runExecute / printExecute consume.
    ///      Run with `--broadcast --rpc-url` so the impl is actually deployed and the printed
    ///      newImpl is a real on-chain address.
    /// @param timeLock   TimelockController governing the ProxyAdmin (the Safe tx target).
    /// @param proxyAdmin ProxyAdmin contract that owns the proxy (the scheduled op's target).
    /// @param proxy      TransparentUpgradeableProxy to upgrade.
    /// @param salt       Unique bytes32 salt for this upgrade operation.
    function printSchedule(address timeLock, address proxyAdmin, address proxy, bytes32 salt) external {
        // Deploy the new implementation (permissionless) — the only broadcast in this path.
        vm.startBroadcast();
        address newImpl = _deployNewImplementation();
        vm.stopBroadcast();

        bytes memory upgradeCalldata = _buildUpgradeCalldata(proxy, newImpl, "");
        uint256 minDelay = _getMinDelay(timeLock);
        bytes memory scheduleCalldata = _buildScheduleCalldata(proxyAdmin, upgradeCalldata, salt, minDelay);
        bytes32 operationId = _computeOperationId(proxyAdmin, upgradeCalldata, salt);

        // Persist the record so printExecute (and runExecute) can rebuild the operation later.
        string memory jsonPath = _writeScheduleRecord(
            _contractName(), operationId, salt, newImpl, proxyAdmin, proxy, block.timestamp, minDelay
        );

        console.log(string.concat("=== ", _contractName(), " Upgrade - SCHEDULE via Safe ==="));
        console.log("Submit this through the Safe (PROPOSER_ROLE). Safe transaction:");
        console.log("  to:    ", timeLock);
        console.log("  value:  0");
        console.log("  data:  ", vm.toString(scheduleCalldata));
        console.log("New Impl:     ", newImpl);
        console.log("OperationId:  ", vm.toString(operationId));
        console.log("Salt:         ", vm.toString(salt));
        console.log("MinDelay (s): ", minDelay);
        console.log("Schedule JSON:", jsonPath);
    }

    /// @notice PRINT the TimeLock.execute() calldata to submit through the Safe after the delay —
    ///         the post-handover counterpart to runExecute. Broadcasts nothing.
    /// @dev Rebuilds the upgrade calldata from the JSON record so the operationId matches the
    ///      scheduled operation. The operator relays the printed calldata to the TimeLock through
    ///      the Safe (`to` = TimeLock, `value` = 0, `data` = printed bytes).
    /// @param timeLock         TimelockController governing the ProxyAdmin (the Safe tx target).
    /// @param proxyAdmin       ProxyAdmin contract that owns the proxy (the scheduled op's target).
    /// @param proxy            TransparentUpgradeableProxy to upgrade.
    /// @param scheduleJsonPath Path to the JSON record written by printSchedule / runSchedule.
    function printExecute(address timeLock, address proxyAdmin, address proxy, string memory scheduleJsonPath)
        external
    {
        string memory json = vm.readFile(scheduleJsonPath);
        bytes32 salt = vm.parseJsonBytes32(json, ".salt");
        address newImpl = vm.parseJsonAddress(json, ".newImpl");

        bytes memory upgradeCalldata = _buildUpgradeCalldata(proxy, newImpl, "");
        bytes memory executeCalldata = _buildExecuteCalldata(proxyAdmin, upgradeCalldata, salt);
        bytes32 operationId = _computeOperationId(proxyAdmin, upgradeCalldata, salt);

        console.log(string.concat("=== ", _contractName(), " Upgrade - EXECUTE via Safe ==="));
        console.log("Submit this through the Safe (EXECUTOR_ROLE) AFTER the delay. Safe transaction:");
        console.log("  to:    ", timeLock);
        console.log("  value:  0");
        console.log("  data:  ", vm.toString(executeCalldata));
        console.log("New Impl:    ", newImpl);
        console.log("OperationId: ", vm.toString(operationId));
        console.log("Salt:        ", vm.toString(salt));
    }

    // ─────────────────────────── JSON Record Helper ──────────────────────────── //

    /// @notice Write a scheduled-upgrade JSON record to deployments/.
    /// @dev Uses operationId as the JSON object key to prevent cross-call state
    ///      contamination when multiple upgrades are scheduled in the same test session.
    function _writeScheduleRecord(
        string memory contractName,
        bytes32 operationId,
        bytes32 salt,
        address newImpl,
        address proxyAdmin,
        address proxy,
        uint256 scheduledAt,
        uint256 minDelay
    ) internal returns (string memory jsonPath) {
        // Unique key per operation prevents Forge VM JSON state leakage between calls
        string memory objKey = string.concat("scheduleRecord-", vm.toString(operationId));

        vm.serializeString(objKey, "contractName", contractName);
        vm.serializeBytes32(objKey, "operationId", operationId);
        vm.serializeBytes32(objKey, "salt", salt);
        vm.serializeAddress(objKey, "newImpl", newImpl);
        vm.serializeAddress(objKey, "proxyAdmin", proxyAdmin);
        vm.serializeAddress(objKey, "proxy", proxy);
        vm.serializeUint(objKey, "scheduledAt", scheduledAt);
        vm.serializeUint(objKey, "minDelay", minDelay);
        string memory jsonOut = vm.serializeUint(objKey, "readyAt", scheduledAt + minDelay);

        // Ensure deployments/ directory exists (idempotent)
        vm.createDir("deployments", true);

        // File name is deterministic: derived from operationId (unique per scheduled op)
        jsonPath = string.concat("deployments/scheduled-upgrade-", contractName, "-", vm.toString(operationId), ".json");
        vm.writeJson(jsonOut, jsonPath);
    }
}
