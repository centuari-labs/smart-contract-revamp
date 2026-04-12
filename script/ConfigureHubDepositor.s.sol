// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {HubDepositor} from "../src/core/cross-chain/HubDepositor.sol";

/// @title ConfigureHubDepositor
/// @notice Script to register supported assets on HubDepositor.
/// @dev Called after HubDepositor is deployed. Accepts a variable number of
///      token addresses to whitelist via `addSupportedAsset`. Only the
///      HubDepositor owner can call this.
contract ConfigureHubDepositor is Script {
    /// @notice Register one or more assets as supported on HubDepositor.
    /// @param hubDepositor HubDepositor proxy address
    /// @param assets Array of ERC20 token addresses to whitelist
    function run(address hubDepositor, address[] calldata assets) external {
        vm.startBroadcast();

        HubDepositor depositor = HubDepositor(hubDepositor);

        for (uint256 i = 0; i < assets.length; i++) {
            depositor.addSupportedAsset(assets[i]);
            console.log("Added supported asset:", assets[i]);
        }

        vm.stopBroadcast();

        console.log("=== HubDepositor Configuration Complete ===");
        console.log("HubDepositor:", hubDepositor);
        console.log("Assets added:", assets.length);
    }
}
