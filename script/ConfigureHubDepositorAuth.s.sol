// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {HubDepositor} from "../src/core/cross-chain/HubDepositor.sol";

/// @title ConfigureHubDepositorAuth
/// @notice Authorize WithdrawalRegistry as a caller on HubDepositor so it can
///         call `payoutDirect` for hub-native withdrawals.
contract ConfigureHubDepositorAuth is Script {
    /// @notice Set WithdrawalRegistry as an authorized caller on HubDepositor.
    /// @param hubDepositor HubDepositor proxy address
    /// @param withdrawalRegistry WithdrawalRegistry proxy address
    function run(address hubDepositor, address withdrawalRegistry) external {
        vm.startBroadcast();

        HubDepositor(hubDepositor).setAuthorizedCaller(withdrawalRegistry, true);

        vm.stopBroadcast();

        console.log("=== HubDepositor Auth Configuration Complete ===");
        console.log("HubDepositor:", hubDepositor);
        console.log("Authorized caller: WithdrawalRegistry", withdrawalRegistry);
    }
}
