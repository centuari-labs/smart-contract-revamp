// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {WithdrawalRegistry} from "../src/core/cross-chain/WithdrawalRegistry.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @title UpgradeWithdrawalRegistry
/// @notice Upgrade script for the WithdrawalRegistry contract.
/// @dev Deploys a new WithdrawalRegistry implementation and points the existing
///      proxy at it. Used to ship the `requestWithdrawalFor` operator entrypoint
///      (Track C6, hub-only). No storage was added, so no re-initialization is
///      required. The caller must be the owner of the ProxyAdmin.
contract UpgradeWithdrawalRegistry is Script {
    /// @notice Upgrade to a new WithdrawalRegistry implementation
    /// @param proxyAdmin The ProxyAdmin contract address
    /// @param proxy The TransparentUpgradeableProxy address
    /// @return newImplementation The new implementation address
    function run(address proxyAdmin, address proxy) external returns (address newImplementation) {
        vm.startBroadcast();

        newImplementation = upgrade(proxyAdmin, proxy);

        vm.stopBroadcast();

        console.log("=== WithdrawalRegistry Upgrade Complete ===");
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
        // 1. Deploy new WithdrawalRegistry implementation
        WithdrawalRegistry newImpl = new WithdrawalRegistry();
        newImplementation = address(newImpl);

        // 2. Upgrade proxy to new implementation (no re-init: storage unchanged)
        ProxyAdmin(proxyAdmin).upgradeAndCall(ITransparentUpgradeableProxy(proxy), newImplementation, "");

        return newImplementation;
    }

    /// @notice Upgrade to a specific implementation address (useful for testing)
    /// @param proxyAdmin The ProxyAdmin contract address
    /// @param proxy The TransparentUpgradeableProxy address
    /// @param newImplementation The new implementation address to upgrade to
    function upgradeToImplementation(address proxyAdmin, address proxy, address newImplementation) public {
        ProxyAdmin(proxyAdmin).upgradeAndCall(ITransparentUpgradeableProxy(proxy), newImplementation, "");
    }
}
