// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UpgradeScriptBase} from "./timelock/UpgradeScriptBase.sol";
import {SpokeVaultStable} from "../src/core/cross-chain/spoke/SpokeVaultStable.sol";

/// @title UpgradeSpokeVaultStable
/// @notice Schedules and executes a SpokeVaultStable proxy upgrade via TimelockController.
/// @dev ProxyAdmin is owned by a per-chain TimelockController — direct upgradeAndCall() is
///      no longer possible. Use the two-step flow:
///        1. runSchedule: deploys new impl + calls TimeLock.schedule()
///        2. runExecute:  calls TimeLock.execute() after minDelay has elapsed
///      runCancel cancels a pending scheduled operation.
///
///      Use the spoke chain's RPC_URL and SPOKE_TIMELOCK_ADDRESS for this script.
///
///      Foundry invocation examples:
///        # Schedule
///        forge script script/UpgradeSpokeVaultStable.s.sol:UpgradeSpokeVaultStable \
///          --sig "runSchedule(address,address,address,bytes32)" \
///          $SPOKE_TIMELOCK $PROXY_ADMIN $PROXY $SALT --broadcast --rpc-url $SPOKE_RPC_URL
///
///        # Execute (after minDelay)
///        forge script script/UpgradeSpokeVaultStable.s.sol:UpgradeSpokeVaultStable \
///          --sig "runExecute(address,address,address,string)" \
///          $SPOKE_TIMELOCK $PROXY_ADMIN $PROXY "deployments/scheduled-upgrade-SpokeVaultStable-0x....json" \
///          --broadcast --rpc-url $SPOKE_RPC_URL
contract UpgradeSpokeVaultStable is UpgradeScriptBase {
    function _contractName() internal pure override returns (string memory) {
        return "SpokeVaultStable";
    }

    function _deployNewImplementation() internal override returns (address) {
        return address(new SpokeVaultStable());
    }
}
