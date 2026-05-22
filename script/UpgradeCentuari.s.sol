// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {Centuari} from "../src/core/centuari/Centuari.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @title UpgradeCentuari
/// @notice Upgrade the Centuari transparent proxy to the Phase 3 (C6) impl that
///         adds per-borrower debt-market enumeration: `_borrowerMarkets` +
///         `_marketLoanToken` storage, `getBorrowerDebts` / `getBorrowerMarkets`
///         views, and the operator `seedBorrowerMarkets` backfill.
/// @dev APPEND-ONLY storage change, verified against
///      `test/snapshots/Centuari.storage.json`: slots 0-8 unchanged, `__gap`
///      shrunk 40 → 38. No `reinitializer` is needed — the new mappings default
///      empty and are populated lazily by `settleMatch` / `repay`, plus the
///      operator `seedBorrowerMarkets` backfill for positions that predate the
///      upgrade. Mirrors `UpgradeCollateralManager.s.sol`. The caller must own
///      the ProxyAdmin.
contract UpgradeCentuari is Script {
    /// @notice Upgrade to a new Centuari implementation
    /// @param proxyAdmin The ProxyAdmin contract address
    /// @param proxy The TransparentUpgradeableProxy address
    /// @return newImplementation The new implementation address
    function run(address proxyAdmin, address proxy) external returns (address newImplementation) {
        vm.startBroadcast();

        newImplementation = upgrade(proxyAdmin, proxy);

        vm.stopBroadcast();

        console.log("=== Centuari Upgrade Complete (Phase 3 / C6 debt enumeration) ===");
        console.log("Proxy:", proxy);
        console.log("ProxyAdmin:", proxyAdmin);
        console.log("New Implementation:", newImplementation);
        console.log("NOTE: operator must seedBorrowerMarkets() for pre-upgrade borrowers");

        return newImplementation;
    }

    /// @notice Deploy a fresh Centuari implementation and upgrade the proxy
    /// @param proxyAdmin The ProxyAdmin contract address
    /// @param proxy The TransparentUpgradeableProxy address
    /// @return newImplementation The new implementation address
    function upgrade(address proxyAdmin, address proxy) public returns (address newImplementation) {
        Centuari newImpl = new Centuari();
        newImplementation = address(newImpl);

        // Empty initData: append-only storage, no reinitializer required.
        ProxyAdmin(proxyAdmin).upgradeAndCall(ITransparentUpgradeableProxy(proxy), newImplementation, "");

        return newImplementation;
    }
}
