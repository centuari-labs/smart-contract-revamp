// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console} from "forge-std/Script.sol";
import {DeployScriptBase} from "./base/DeployScriptBase.sol";
import {HubDepositor} from "../src/core/cross-chain/HubDepositor.sol";
import {BalanceLedger} from "../src/core/balance-ledger/BalanceLedger.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @title DeployHubDepositor
/// @notice Deployment script for HubDepositor (implementation + TransparentUpgradeableProxy).
/// @dev Requires a deployed BalanceLedger proxy address. HubDepositor must be
///      registered as an authorized writer on BalanceLedger via ConfigureBalanceLedger.
contract DeployHubDepositor is DeployScriptBase {
    /// @notice Deploy HubDepositor (impl + proxy).
    /// @param owner HubDepositor owner (governance / multisig)
    /// @param balanceLedger BalanceLedger proxy address
    /// @param proxyAdminOwner Owner of the ProxyAdmin (e.g. multisig)
    /// @param assets ERC20 tokens to whitelist as supported deposit assets
    /// @return hubDepositorProxy HubDepositor proxy address
    /// @return hubDepositorImpl HubDepositor implementation address
    /// @return proxyAdmin ProxyAdmin address
    function run(address owner, address balanceLedger, address proxyAdminOwner, address[] calldata assets)
        external
        returns (address hubDepositorProxy, address hubDepositorImpl, address proxyAdmin)
    {
        vm.startBroadcast();

        (hubDepositorProxy, hubDepositorImpl, proxyAdmin) = deploy(owner, balanceLedger, proxyAdminOwner);

        // Register HubDepositor as an authorized BalanceLedger writer (folded from
        // ConfigureBalanceLedger Phase 1). Testnet forceAddWriter fast path, guarded.
        if (!BalanceLedger(balanceLedger).isAuthorizedWriter(hubDepositorProxy)) {
            BalanceLedger(balanceLedger).forceAddWriter(hubDepositorProxy);
            console.log("Added writer: HubDepositor", hubDepositorProxy);
        }

        // Whitelist supported deposit assets (folded from ConfigureHubDepositor).
        for (uint256 i = 0; i < assets.length; i++) {
            HubDepositor(hubDepositorProxy).addSupportedAsset(assets[i]);
            console.log("Added supported asset:", assets[i]);
        }

        vm.stopBroadcast();

        console.log("=== HubDepositor Deployment Complete ===");
        console.log("HubDepositor implementation:", hubDepositorImpl);
        console.log("HubDepositor proxy:", hubDepositorProxy);
        console.log("ProxyAdmin:", proxyAdmin);
        console.log("Owner:", owner);
        console.log("BalanceLedger:", balanceLedger);
        console.log("ProxyAdmin Owner:", proxyAdminOwner);

        return (hubDepositorProxy, hubDepositorImpl, proxyAdmin);
    }

    /// @notice Deploy HubDepositor impl + proxy.
    /// @param owner HubDepositor owner
    /// @param balanceLedger BalanceLedger proxy address
    /// @param proxyAdminOwner Owner of the ProxyAdmin
    function deploy(address owner, address balanceLedger, address proxyAdminOwner)
        public
        returns (address hubDepositorProxy, address hubDepositorImpl, address proxyAdmin)
    {
        HubDepositor impl = new HubDepositor();
        hubDepositorImpl = address(impl);

        bytes memory initData = abi.encodeCall(HubDepositor.initialize, (owner, balanceLedger));

        TransparentUpgradeableProxy transparentProxy =
            new TransparentUpgradeableProxy(hubDepositorImpl, proxyAdminOwner, initData);
        hubDepositorProxy = address(transparentProxy);

        proxyAdmin = _getProxyAdmin(hubDepositorProxy);

        return (hubDepositorProxy, hubDepositorImpl, proxyAdmin);
    }
}
