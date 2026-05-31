// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {RiskModule} from "../src/core/risk/RiskModule.sol";

/// @notice Upgrade the RiskModule implementation behind its ERC1967 proxy.
/// @dev Deploys a new RiskModule impl (adds the view-only healthFactor /
///      isLiquidatable getters; no storage change) and calls
///      ProxyAdmin.upgradeAndCall with empty calldata (no reinitializer). On
///      mainnet the ProxyAdmin owner is the timelock; run through the timelock
///      schedule/execute flow (see script/timelock/). Mirrors UpgradeCentuari.
contract UpgradeRiskModule is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address proxy = vm.envAddress("RISK_MODULE_PROXY");
        address proxyAdmin = vm.envAddress("RISK_MODULE_PROXY_ADMIN");

        vm.startBroadcast(pk);

        RiskModule newImpl = new RiskModule();
        console.log("RISK_MODULE_NEW_IMPL=", address(newImpl));

        ProxyAdmin(proxyAdmin).upgradeAndCall(ITransparentUpgradeableProxy(proxy), address(newImpl), "");

        vm.stopBroadcast();
    }
}
