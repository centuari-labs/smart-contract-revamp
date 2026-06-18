// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {Centuari} from "../src/core/centuari/Centuari.sol";
import {CentuariBondERC20Factory} from "../src/core/centuari/CentuariBondERC20Factory.sol";

/// @title DeployBondFactory
/// @notice Deployment script for CentuariBondERC20Factory.
/// @dev Deploys the factory pointing at an existing Centuari proxy.
contract DeployBondFactory is Script {
    /// @notice Deploy CentuariBondERC20Factory for a given Centuari proxy.
    /// @param centuari Centuari proxy address
    /// @return factory Deployed CentuariBondERC20Factory address
    function run(address centuari) external returns (address factory) {
        vm.startBroadcast();

        factory = deploy(centuari);

        // Wire the freshly deployed factory into Centuari (folded from ConfigureBondFactory).
        Centuari(centuari).setBondTokenFactory(factory);

        vm.stopBroadcast();

        console.log("=== Bond Factory Deployment Complete ===");
        console.log("BondFactory:", factory);
        console.log("Wired BondFactory into Centuari:", centuari);
    }

    /// @notice Deploy the factory contract.
    /// @param centuari Centuari proxy address
    /// @return factory Deployed factory address
    function deploy(address centuari) public returns (address factory) {
        CentuariBondERC20Factory factoryContract = new CentuariBondERC20Factory(centuari);
        factory = address(factoryContract);
        return factory;
    }
}
