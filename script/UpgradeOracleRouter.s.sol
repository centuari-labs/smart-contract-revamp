// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UpgradeScriptBase} from "./timelock/UpgradeScriptBase.sol";
import {OracleRouter} from "../src/core/oracle/OracleRouter.sol";

/// @title UpgradeOracleRouter
/// @notice Schedules and executes an OracleRouter proxy upgrade via TimelockController.
/// @dev ProxyAdmin is owned by a TimelockController — direct upgradeAndCall() is no longer
///      possible. Use the two-step flow:
///        1. runSchedule: deploys new impl + calls TimeLock.schedule()
///        2. runExecute:  calls TimeLock.execute() after minDelay has elapsed
///      runCancel cancels a pending scheduled operation.
///
///      Foundry invocation examples:
///        # Schedule
///        forge script script/UpgradeOracleRouter.s.sol:UpgradeOracleRouter \
///          --sig "runSchedule(address,address,address,bytes32)" \
///          $TIMELOCK $PROXY_ADMIN $PROXY $SALT --broadcast --rpc-url $RPC_URL
///
///        # Execute (after minDelay)
///        forge script script/UpgradeOracleRouter.s.sol:UpgradeOracleRouter \
///          --sig "runExecute(address,address,address,string)" \
///          $TIMELOCK $PROXY_ADMIN $PROXY "deployments/scheduled-upgrade-OracleRouter-0x....json" \
///          --broadcast --rpc-url $RPC_URL
///
///        # Cancel
///        forge script script/UpgradeOracleRouter.s.sol:UpgradeOracleRouter \
///          --sig "runCancel(address,string)" \
///          $TIMELOCK "deployments/scheduled-upgrade-OracleRouter-0x....json" \
///          --broadcast --rpc-url $RPC_URL
contract UpgradeOracleRouter is UpgradeScriptBase {
    function _contractName() internal pure override returns (string memory) {
        return "OracleRouter";
    }

    function _deployNewImplementation() internal override returns (address) {
        return address(new OracleRouter());
    }
}
