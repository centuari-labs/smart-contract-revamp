// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {Settlement} from "../src/core/settlement/Settlement.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @title UpgradeSettlement
/// @notice Upgrade script for Settlement contract
/// @dev Upgrades an existing Settlement proxy to a new implementation
///      The caller must be the owner of the ProxyAdmin
contract UpgradeSettlement is Script {
    /// @notice Upgrade to a new Settlement implementation
    /// @param proxyAdmin The ProxyAdmin contract address
    /// @param proxy The TransparentUpgradeableProxy address
    /// @return newImplementation The new implementation address
    function run(address proxyAdmin, address proxy) external returns (address newImplementation) {
        vm.startBroadcast();

        newImplementation = upgrade(proxyAdmin, proxy);

        vm.stopBroadcast();

        console.log("=== Settlement Upgrade Complete ===");
        console.log("Proxy:", proxy);
        console.log("ProxyAdmin:", proxyAdmin);
        console.log("New Implementation:", newImplementation);

        return newImplementation;
    }

    /// @notice Upgrade to a new Settlement implementation with initialization
    /// @param proxyAdmin The ProxyAdmin contract address
    /// @param proxy The TransparentUpgradeableProxy address
    /// @param initData The initialization data for the new implementation (if any)
    /// @return newImplementation The new implementation address
    function runWithInit(address proxyAdmin, address proxy, bytes calldata initData)
        external
        returns (address newImplementation)
    {
        vm.startBroadcast();

        newImplementation = upgradeAndCall(proxyAdmin, proxy, initData);

        vm.stopBroadcast();

        console.log("=== Settlement Upgrade Complete ===");
        console.log("Proxy:", proxy);
        console.log("ProxyAdmin:", proxyAdmin);
        console.log("New Implementation:", newImplementation);

        return newImplementation;
    }

    /// @notice Deploy new implementation and upgrade the proxy
    /// @param proxyAdmin The ProxyAdmin contract address
    /// @param proxy The TransparentUpgradeableProxy address
    /// @return newImplementation The new implementation address
    function upgrade(address proxyAdmin, address proxy) public returns (address newImplementation) {
        // 1. Deploy new Settlement implementation
        Settlement newSettlementImpl = new Settlement();
        newImplementation = address(newSettlementImpl);

        // 2. Upgrade proxy to new implementation
        ProxyAdmin(proxyAdmin).upgradeAndCall(
            ITransparentUpgradeableProxy(proxy),
            newImplementation,
            "" // No initialization data for simple upgrade
        );

        return newImplementation;
    }

    /// @notice Deploy new implementation and upgrade with initialization
    /// @param proxyAdmin The ProxyAdmin contract address
    /// @param proxy The TransparentUpgradeableProxy address
    /// @param initData The initialization data for the new implementation
    /// @return newImplementation The new implementation address
    function upgradeAndCall(address proxyAdmin, address proxy, bytes memory initData)
        public
        returns (address newImplementation)
    {
        // 1. Deploy new Settlement implementation
        Settlement newSettlementImpl = new Settlement();
        newImplementation = address(newSettlementImpl);

        // 2. Upgrade proxy to new implementation with initialization
        ProxyAdmin(proxyAdmin).upgradeAndCall(ITransparentUpgradeableProxy(proxy), newImplementation, initData);

        return newImplementation;
    }

    /// @notice Upgrade to a specific implementation address (useful for testing)
    /// @param proxyAdmin The ProxyAdmin contract address
    /// @param proxy The TransparentUpgradeableProxy address
    /// @param newImplementation The new implementation address to upgrade to
    function upgradeToImplementation(address proxyAdmin, address proxy, address newImplementation) public {
        ProxyAdmin(proxyAdmin).upgradeAndCall(ITransparentUpgradeableProxy(proxy), newImplementation, "");
    }

    /// @notice Upgrade to a specific implementation address with initialization
    /// @param proxyAdmin The ProxyAdmin contract address
    /// @param proxy The TransparentUpgradeableProxy address
    /// @param newImplementation The new implementation address to upgrade to
    /// @param initData The initialization data for the new implementation
    function upgradeToImplementationAndCall(
        address proxyAdmin,
        address proxy,
        address newImplementation,
        bytes memory initData
    ) public {
        ProxyAdmin(proxyAdmin).upgradeAndCall(ITransparentUpgradeableProxy(proxy), newImplementation, initData);
    }
}
