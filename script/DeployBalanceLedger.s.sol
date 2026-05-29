// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console} from "forge-std/Script.sol";
import {DeployScriptBase} from "./base/DeployScriptBase.sol";
import {BalanceLedger} from "../src/core/balance-ledger/BalanceLedger.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @title DeployBalanceLedger
/// @notice Deployment script for BalanceLedger (implementation + TransparentUpgradeableProxy).
/// @dev On testnet, forceWriterRegistrationEnabled is set to true so that
///      ConfigureBalanceLedger can register writers immediately via forceAddWriter.
///      MUST be false for mainnet production deployments.
contract DeployBalanceLedger is DeployScriptBase {
    /// @notice Deploy BalanceLedger (impl + proxy).
    /// @param owner BalanceLedger owner (can manage writers and pause)
    /// @param forceWriterRegistrationEnabled Whether forceAddWriter is permitted
    /// @param proxyAdminOwner Owner of the ProxyAdmin (e.g. multisig)
    /// @return balanceLedgerProxy BalanceLedger proxy address
    /// @return balanceLedgerImpl BalanceLedger implementation address
    /// @return proxyAdmin ProxyAdmin address
    function run(address owner, bool forceWriterRegistrationEnabled, address proxyAdminOwner)
        external
        returns (address balanceLedgerProxy, address balanceLedgerImpl, address proxyAdmin)
    {
        vm.startBroadcast();

        (balanceLedgerProxy, balanceLedgerImpl, proxyAdmin) =
            deploy(owner, forceWriterRegistrationEnabled, proxyAdminOwner);

        vm.stopBroadcast();

        console.log("=== BalanceLedger Deployment Complete ===");
        console.log("BalanceLedger implementation:", balanceLedgerImpl);
        console.log("BalanceLedger proxy:", balanceLedgerProxy);
        console.log("ProxyAdmin:", proxyAdmin);
        console.log("Owner:", owner);
        console.log("Force writer registration:", forceWriterRegistrationEnabled);
        console.log("ProxyAdmin Owner:", proxyAdminOwner);

        return (balanceLedgerProxy, balanceLedgerImpl, proxyAdmin);
    }

    /// @notice Deploy BalanceLedger impl + proxy.
    /// @param owner BalanceLedger owner
    /// @param forceWriterRegistrationEnabled Whether forceAddWriter is permitted
    /// @param proxyAdminOwner Owner of the ProxyAdmin
    function deploy(address owner, bool forceWriterRegistrationEnabled, address proxyAdminOwner)
        public
        returns (address balanceLedgerProxy, address balanceLedgerImpl, address proxyAdmin)
    {
        BalanceLedger impl = new BalanceLedger();
        balanceLedgerImpl = address(impl);

        bytes memory initData = abi.encodeCall(BalanceLedger.initialize, (owner, forceWriterRegistrationEnabled));

        TransparentUpgradeableProxy transparentProxy =
            new TransparentUpgradeableProxy(balanceLedgerImpl, proxyAdminOwner, initData);
        balanceLedgerProxy = address(transparentProxy);

        proxyAdmin = _getProxyAdmin(balanceLedgerProxy);

        return (balanceLedgerProxy, balanceLedgerImpl, proxyAdmin);
    }
}
