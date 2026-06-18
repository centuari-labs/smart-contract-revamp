// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UpgradeScriptBase} from "./timelock/UpgradeScriptBase.sol";
import {CollateralManager} from "../src/core/collateral/CollateralManager.sol";

/// @title UpgradeCollateralManager
/// @notice Schedules and executes a CollateralManager proxy upgrade via TimelockController.
/// @dev ProxyAdmin is owned by a TimelockController — direct upgradeAndCall() is no longer
///      possible. Use the two-step flow:
///        1. runSchedule: deploys new impl + calls TimeLock.schedule()
///        2. runExecute:  calls TimeLock.execute() after minDelay has elapsed
///      runCancel cancels a pending scheduled operation.
///
///      Foundry invocation examples:
///        # Schedule
///        forge script script/UpgradeCollateralManager.s.sol:UpgradeCollateralManager \
///          --sig "runSchedule(address,address,address,bytes32)" \
///          $TIMELOCK $PROXY_ADMIN $PROXY $SALT --broadcast --rpc-url $RPC_URL
///
///        # Execute (after minDelay)
///        forge script script/UpgradeCollateralManager.s.sol:UpgradeCollateralManager \
///          --sig "runExecute(address,address,address,string)" \
///          $TIMELOCK $PROXY_ADMIN $PROXY "deployments/scheduled-upgrade-CollateralManager-0x....json" \
///          --broadcast --rpc-url $RPC_URL
contract UpgradeCollateralManager is UpgradeScriptBase {
    function _contractName() internal pure override returns (string memory) {
        return "CollateralManager";
    }

    function _deployNewImplementation() internal override returns (address) {
        return address(new CollateralManager());
    }
}
