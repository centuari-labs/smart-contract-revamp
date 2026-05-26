// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UpgradeScriptBase} from "./timelock/UpgradeScriptBase.sol";
import {SpokePayout} from "../src/core/cross-chain/spoke/SpokePayout.sol";

/// @title UpgradeSpokePayout
/// @notice Schedules and executes a SpokePayout proxy upgrade via TimelockController.
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
///        forge script script/UpgradeSpokePayout.s.sol:UpgradeSpokePayout \
///          --sig "runSchedule(address,address,address,bytes32)" \
///          $SPOKE_TIMELOCK $PROXY_ADMIN $PROXY $SALT --broadcast --rpc-url $SPOKE_RPC_URL
///
///        # Execute (after minDelay)
///        forge script script/UpgradeSpokePayout.s.sol:UpgradeSpokePayout \
///          --sig "runExecute(address,address,address,string)" \
///          $SPOKE_TIMELOCK $PROXY_ADMIN $PROXY "deployments/scheduled-upgrade-SpokePayout-0x....json" \
///          --broadcast --rpc-url $SPOKE_RPC_URL
contract UpgradeSpokePayout is UpgradeScriptBase {
    function _contractName() internal pure override returns (string memory) {
        return "SpokePayout";
    }

    function _deployNewImplementation() internal override returns (address) {
        return address(new SpokePayout());
    }
}
