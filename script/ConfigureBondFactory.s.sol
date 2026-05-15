// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {Centuari} from "../src/core/centuari/Centuari.sol";

/// @title ConfigureBondFactory
/// @notice Script to wire a deployed CentuariBondERC20Factory into an existing Centuari proxy.
/// @dev Calls Centuari.setBondTokenFactory(factory) as the Centuari owner.
contract ConfigureBondFactory is Script {
    /// @notice Set the bond token factory on Centuari.
    /// @param centuari Centuari proxy address
    /// @param factory Deployed CentuariBondERC20Factory address
    function run(address centuari, address factory) external {
        vm.startBroadcast();

        Centuari(centuari).setBondTokenFactory(factory);

        vm.stopBroadcast();

        console.log("=== Bond Factory Configuration Complete ===");
        console.log("Centuari:", centuari);
        console.log("BondFactory:", factory);
    }
}
