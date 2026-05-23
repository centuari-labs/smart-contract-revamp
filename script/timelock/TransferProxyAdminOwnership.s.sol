// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

/// @title TransferProxyAdminOwnership
/// @notice One-time migration script: transfers ownership of existing ProxyAdmin contracts
///         to a deployed TimelockController.
/// @dev Use this for contracts that were deployed BEFORE TimeLock governance was introduced.
///      New deployments should pass the TimeLock address directly as `proxyAdminOwner`.
///
///      The caller must be the current owner of every ProxyAdmin in the array.
///      Run once per chain after deploying the TimelockController.
///
///      Hub example (run-all.sh context):
///        forge script script/timelock/TransferProxyAdminOwnership.s.sol \
///          --sig "run(address,address[])" \
///          $TIMELOCK_ADDRESS "[$PROXY_ADMIN_BL,$PROXY_ADMIN_CT,$PROXY_ADMIN_ST,...]" \
///          --broadcast --rpc-url $RPC_URL
///
///      Helper: bin/transfer-proxy-admin-ownership.sh reads addresses from
///              deployments/deploy-<network>-latest.json automatically.
contract TransferProxyAdminOwnership is Script {
    /// @notice Transfer ownership of all given ProxyAdmins to the TimelockController.
    /// @param timeLock    Target TimelockController address (new owner of each ProxyAdmin).
    /// @param proxyAdmins Array of ProxyAdmin addresses whose ownership will be transferred.
    function run(address timeLock, address[] calldata proxyAdmins) external {
        require(timeLock != address(0), "TransferProxyAdminOwnership: timeLock is zero address");

        console.log("=== TransferProxyAdminOwnership ===");
        console.log("Target TimeLock:", timeLock);
        console.log("ProxyAdmins:    ", proxyAdmins.length);

        if (proxyAdmins.length == 0) {
            console.log("No ProxyAdmins provided - nothing to transfer.");
            return;
        }

        vm.startBroadcast();

        for (uint256 i = 0; i < proxyAdmins.length; i++) {
            address pa = proxyAdmins[i];
            address currentOwner = ProxyAdmin(pa).owner();
            ProxyAdmin(pa).transferOwnership(timeLock);
            console.log(string.concat("  [", vm.toString(i), "] ProxyAdmin: "), pa);
            console.log("       Before:", currentOwner);
            console.log("       After: ", timeLock);
        }

        vm.stopBroadcast();

        // Verify all transfers succeeded
        bool allTransferred = true;
        for (uint256 i = 0; i < proxyAdmins.length; i++) {
            address newOwner = ProxyAdmin(proxyAdmins[i]).owner();
            if (newOwner != timeLock) {
                console.log("ERROR: transfer failed for ProxyAdmin:", proxyAdmins[i]);
                allTransferred = false;
            }
        }
        require(allTransferred, "TransferProxyAdminOwnership: one or more transfers failed");

        console.log("=== All ProxyAdmins transferred to TimeLock ===");
        console.log("TimeLock: ", timeLock);
        console.log("Count:    ", proxyAdmins.length);
    }
}
