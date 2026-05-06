// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {HubDepositor} from "../src/core/cross-chain/HubDepositor.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @title DeployHubDepositor
/// @notice Deployment script for HubDepositor (implementation + TransparentUpgradeableProxy).
/// @dev Requires a deployed BalanceLedger proxy address. HubDepositor must be
///      registered as an authorized writer on BalanceLedger via ConfigureBalanceLedger.
contract DeployHubDepositor is Script {
    /// @notice Deploy HubDepositor (impl + proxy).
    /// @param owner HubDepositor owner (governance / multisig)
    /// @param balanceLedger BalanceLedger proxy address
    /// @param proxyAdminOwner Owner of the ProxyAdmin (e.g. multisig)
    /// @return hubDepositorProxy HubDepositor proxy address
    /// @return hubDepositorImpl HubDepositor implementation address
    /// @return proxyAdmin ProxyAdmin address
    function run(address owner, address balanceLedger, address proxyAdminOwner)
        external
        returns (address hubDepositorProxy, address hubDepositorImpl, address proxyAdmin)
    {
        vm.startBroadcast();

        (hubDepositorProxy, hubDepositorImpl, proxyAdmin) = deploy(owner, balanceLedger, proxyAdminOwner);

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

    /// @notice Get the ProxyAdmin address from a TransparentUpgradeableProxy
    /// @dev Reads the admin address from ERC1967 admin slot
    function _getProxyAdmin(address proxy) internal view returns (address) {
        bytes32 adminSlot = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
        bytes32 adminValue = vm.load(proxy, adminSlot);
        return address(uint160(uint256(adminValue)));
    }
}
