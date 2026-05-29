// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console} from "forge-std/Script.sol";
import {DeployScriptBase} from "./base/DeployScriptBase.sol";
import {Centuari} from "../src/core/centuari/Centuari.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @title DeployCentuari
/// @notice Deployment script for Centuari (implementation + TransparentUpgradeableProxy).
/// @dev Pass the BalanceLedger address from DeployBalanceLedger. Use settlementPlaceholder = owner when deploying
///      before Settlement; then deploy Settlement with this proxy and call Centuari.setSettlement(settlementProxy).
contract DeployCentuari is DeployScriptBase {
    /// @notice Deploy Centuari (impl + proxy).
    /// @param owner Centuari owner
    /// @param settlementPlaceholder Address for Centuari.initialize settlement_ (use owner if Settlement not yet deployed)
    /// @param balanceLedger BalanceLedger contract address
    /// @param feeCollector Address that receives protocol fee credits
    /// @param proxyAdminOwner Owner of the ProxyAdmin (e.g. multisig)
    /// @return centuariProxy Centuari proxy address (use as CENTUARI_ADDRESS for DeploySettlement)
    /// @return centuariImpl Centuari implementation address
    /// @return proxyAdmin ProxyAdmin address
    function run(
        address owner,
        address settlementPlaceholder,
        address balanceLedger,
        address feeCollector,
        address proxyAdminOwner
    ) external returns (address centuariProxy, address centuariImpl, address proxyAdmin) {
        vm.startBroadcast();

        (centuariProxy, centuariImpl, proxyAdmin) =
            deploy(owner, settlementPlaceholder, balanceLedger, feeCollector, proxyAdminOwner);

        vm.stopBroadcast();

        console.log("=== Centuari Deployment Complete ===");
        console.log("Centuari implementation:", centuariImpl);
        console.log("Centuari proxy:", centuariProxy);
        console.log("ProxyAdmin:", proxyAdmin);
        console.log("Owner:", owner);
        console.log("Settlement placeholder:", settlementPlaceholder);
        console.log("BalanceLedger:", balanceLedger);
        console.log("Fee Collector:", feeCollector);
        console.log("ProxyAdmin Owner:", proxyAdminOwner);

        return (centuariProxy, centuariImpl, proxyAdmin);
    }

    /// @notice Deploy Centuari impl + proxy.
    /// @param owner Centuari owner
    /// @param settlementPlaceholder Address for Centuari.initialize settlement_
    /// @param balanceLedger BalanceLedger contract address
    /// @param feeCollector Address that receives protocol fee credits
    /// @param proxyAdminOwner Owner of the ProxyAdmin
    function deploy(
        address owner,
        address settlementPlaceholder,
        address balanceLedger,
        address feeCollector,
        address proxyAdminOwner
    ) public returns (address centuariProxy, address centuariImpl, address proxyAdmin) {
        Centuari centuariImplContract = new Centuari();
        centuariImpl = address(centuariImplContract);

        bytes memory initData =
            abi.encodeCall(Centuari.initialize, (owner, settlementPlaceholder, balanceLedger, feeCollector));

        TransparentUpgradeableProxy transparentProxy =
            new TransparentUpgradeableProxy(centuariImpl, proxyAdminOwner, initData);
        centuariProxy = address(transparentProxy);

        proxyAdmin = _getProxyAdmin(centuariProxy);

        return (centuariProxy, centuariImpl, proxyAdmin);
    }
}
