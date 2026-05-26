// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UpgradeScriptBase} from "./timelock/UpgradeScriptBase.sol";
import {Settlement} from "../src/core/settlement/Settlement.sol";

/// @title UpgradeSettlement
/// @notice Schedules and executes a Settlement proxy upgrade via TimelockController.
/// @dev ProxyAdmin is owned by a TimelockController — direct upgradeAndCall() is no longer
///      possible. Use the two-step flow:
///        1. runSchedule: deploys new impl + calls TimeLock.schedule()
///        2. runExecute:  calls TimeLock.execute() after minDelay has elapsed
///      runCancel cancels a pending scheduled operation.
///
///      Foundry invocation examples:
///        # Schedule (generates deployments/scheduled-upgrade-Settlement-0x....json)
///        forge script script/UpgradeSettlement.s.sol:UpgradeSettlement \
///          --sig "runSchedule(address,address,address,bytes32)" \
///          $TIMELOCK $PROXY_ADMIN $PROXY $SALT --broadcast --rpc-url $RPC_URL
///
///        # Execute (run after minDelay)
///        forge script script/UpgradeSettlement.s.sol:UpgradeSettlement \
///          --sig "runExecute(address,address,address,string)" \
///          $TIMELOCK $PROXY_ADMIN $PROXY "deployments/scheduled-upgrade-Settlement-0x....json" \
///          --broadcast --rpc-url $RPC_URL
///
///        # Cancel
///        forge script script/UpgradeSettlement.s.sol:UpgradeSettlement \
///          --sig "runCancel(address,string)" \
///          $TIMELOCK "deployments/scheduled-upgrade-Settlement-0x....json" \
///          --broadcast --rpc-url $RPC_URL
contract UpgradeSettlement is UpgradeScriptBase {
    function _contractName() internal pure override returns (string memory) {
        return "Settlement";
    }

    function _deployNewImplementation() internal override returns (address) {
        return address(new Settlement());
    }
}
