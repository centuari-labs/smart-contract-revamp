// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

/// @dev Minimal view of the OwnableUpgradeable surface shared by every Centuari
///      core proxy. Selectors match `OwnableUpgradeable`, so casting a proxy
///      address to this interface and calling these is ABI-safe.
interface IOwnable {
    function owner() external view returns (address);
    function transferOwnership(address newOwner) external;
}

/// @title TransferContractOwnership
/// @notice One-time migration script: transfers the contract-level `owner()` of
///         the Centuari core proxies to a new owner (in production: the 24h
///         operational TimelockController). This is the OPERATIONAL owner layer
///         (setOperator, setRiskModule, writer registration, addSupportedAsset,
///         setPauser, ...) — distinct from the ProxyAdmin/upgrade layer handled
///         by TransferProxyAdminOwnership.s.sol (the 48h upgrade timelock).
/// @dev The caller must be the current `owner()` of every target proxy.
///      Run once per chain after deploying the operational TimelockController.
///
///      The guardian (pauser) role is rotated separately via each contract's
///      `setPauser` (to the Safe directly) BEFORE this transfer, while the
///      deployer is still owner — pause()/unpause() must stay off the timelock.
///
///      `OwnableUpgradeable` is single-step: ownership moves immediately and
///      irreversibly. Verify `newOwner` carefully and rehearse on testnet.
///
///      Hub example (run-all.sh context):
///        forge script script/timelock/TransferContractOwnership.s.sol \
///          --sig "run(address,address[])" \
///          $OPS_TIMELOCK "[$BALANCE_LEDGER,$CENTUARI,$SETTLEMENT,...]" \
///          --broadcast --rpc-url $RPC_URL
contract TransferContractOwnership is Script {
    /// @notice Transfer `owner()` of all given proxies to `newOwner`.
    /// @param newOwner Target owner (new owner of each proxy — e.g. the ops TimelockController).
    /// @param targets  Array of proxy addresses whose ownership will be transferred.
    function run(address newOwner, address[] calldata targets) external {
        require(newOwner != address(0), "TransferContractOwnership: newOwner is zero address");

        console.log("=== TransferContractOwnership ===");
        console.log("Target owner:", newOwner);
        console.log("Proxies:     ", targets.length);

        if (targets.length == 0) {
            console.log("No targets provided - nothing to transfer.");
            return;
        }

        vm.startBroadcast();

        for (uint256 i = 0; i < targets.length; i++) {
            address t = targets[i];
            address currentOwner = IOwnable(t).owner();
            IOwnable(t).transferOwnership(newOwner);
            console.log(string.concat("  [", vm.toString(i), "] proxy: "), t);
            console.log("       Before:", currentOwner);
            console.log("       After: ", newOwner);
        }

        vm.stopBroadcast();

        // Verify all transfers succeeded
        bool allTransferred = true;
        for (uint256 i = 0; i < targets.length; i++) {
            address actualOwner = IOwnable(targets[i]).owner();
            if (actualOwner != newOwner) {
                console.log("ERROR: transfer failed for proxy:", targets[i]);
                allTransferred = false;
            }
        }
        require(allTransferred, "TransferContractOwnership: one or more transfers failed");

        console.log("=== All proxy owners transferred ===");
        console.log("New owner:", newOwner);
        console.log("Count:    ", targets.length);
    }
}
