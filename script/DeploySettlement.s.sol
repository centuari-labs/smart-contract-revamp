// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console} from "forge-std/Script.sol";
import {DeployScriptBase} from "./base/DeployScriptBase.sol";
import {Settlement} from "../src/core/settlement/Settlement.sol";
import {BalanceLedger} from "../src/core/balance-ledger/BalanceLedger.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @title DeploySettlement
/// @notice Deployment script for Settlement contract with TransparentUpgradeableProxy
/// @dev Deploys:
///      1. Settlement implementation
///      2. ProxyAdmin (controlled by deployer/multisig)
///      3. TransparentUpgradeableProxy with implementation and admin
///      4. Initializes Settlement via proxy
contract DeploySettlement is DeployScriptBase {
    /// @notice Main deployment function
    /// @param owner The owner address for the Settlement contract
    /// @param operator The settlement engine operator address
    /// @param centuari The Centuari contract address
    /// @param balanceLedger BalanceLedger proxy (Settlement is registered as an authorized writer)
    /// @param proxyAdminOwner The owner of the ProxyAdmin (typically a multisig)
    /// @return proxy The deployed proxy address
    /// @return proxyAdmin The deployed ProxyAdmin address
    /// @return implementation The deployed implementation address
    function run(address owner, address operator, address centuari, address balanceLedger, address proxyAdminOwner)
        external
        returns (address proxy, address proxyAdmin, address implementation)
    {
        vm.startBroadcast();

        (proxy, proxyAdmin, implementation) = deploy(owner, operator, centuari, proxyAdminOwner);

        // Register Settlement as an authorized BalanceLedger writer (folded from
        // ConfigureBalanceLedger Phase 2). Testnet forceAddWriter fast path, guarded.
        if (!BalanceLedger(balanceLedger).isAuthorizedWriter(proxy)) {
            BalanceLedger(balanceLedger).forceAddWriter(proxy);
            console.log("Added writer: Settlement", proxy);
        }

        vm.stopBroadcast();

        console.log("=== Settlement Deployment Complete ===");
        console.log("Implementation:", implementation);
        console.log("ProxyAdmin:", proxyAdmin);
        console.log("Proxy:", proxy);
        console.log("Owner:", owner);
        console.log("Operator:", operator);
        console.log("Centuari:", centuari);
        console.log("ProxyAdmin Owner:", proxyAdminOwner);

        return (proxy, proxyAdmin, implementation);
    }

    /// @notice Deploy Settlement with transparent proxy pattern
    /// @param owner The owner address for the Settlement contract
    /// @param operator The settlement engine operator address
    /// @param centuari The Centuari contract address
    /// @param proxyAdminOwner The owner of the ProxyAdmin
    /// @return proxy The deployed proxy address
    /// @return proxyAdmin The deployed ProxyAdmin address
    /// @return implementation The deployed implementation address
    function deploy(address owner, address operator, address centuari, address proxyAdminOwner)
        public
        returns (address proxy, address proxyAdmin, address implementation)
    {
        // 1. Deploy Settlement implementation
        Settlement settlementImpl = new Settlement();
        implementation = address(settlementImpl);

        // 2. Prepare initialization data
        bytes memory initData = abi.encodeCall(Settlement.initialize, (owner, operator, centuari));

        // 3. Deploy TransparentUpgradeableProxy
        //    Note: TransparentUpgradeableProxy deploys its own ProxyAdmin internally
        //    and transfers ownership to the specified admin address
        TransparentUpgradeableProxy transparentProxy =
            new TransparentUpgradeableProxy(implementation, proxyAdminOwner, initData);
        proxy = address(transparentProxy);

        // 4. Get the ProxyAdmin address
        //    The ProxyAdmin is deployed by the TransparentUpgradeableProxy constructor
        //    and can be retrieved from the proxy's admin slot
        proxyAdmin = _getProxyAdmin(proxy);

        return (proxy, proxyAdmin, implementation);
    }
}
