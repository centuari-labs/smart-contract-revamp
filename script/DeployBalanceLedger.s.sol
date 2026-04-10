// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {BalanceLedger} from "../src/core/balance-ledger/BalanceLedger.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @title DeployBalanceLedger
/// @notice Deployment script for BalanceLedger (implementation + TransparentUpgradeableProxy).
/// @dev On testnet, forceWriterRegistrationEnabled is set to true so that
///      ConfigureBalanceLedger can register writers immediately via forceAddWriter.
///      MUST be false for mainnet production deployments.
contract DeployBalanceLedger is Script {
    /// @notice Deploy BalanceLedger (impl + proxy).
    /// @param owner BalanceLedger owner (can manage writers and pause)
    /// @param forceWriterRegistrationEnabled Whether forceAddWriter is permitted
    /// @param proxyAdminOwner Owner of the ProxyAdmin (e.g. multisig)
    /// @return balanceLedgerProxy BalanceLedger proxy address
    /// @return balanceLedgerImpl BalanceLedger implementation address
    /// @return proxyAdmin ProxyAdmin address
    function run(
        address owner,
        bool forceWriterRegistrationEnabled,
        address proxyAdminOwner
    )
        external
        returns (
            address balanceLedgerProxy,
            address balanceLedgerImpl,
            address proxyAdmin
        )
    {
        vm.startBroadcast();

        (balanceLedgerProxy, balanceLedgerImpl, proxyAdmin) = deploy(
            owner,
            forceWriterRegistrationEnabled,
            proxyAdminOwner
        );

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
    function deploy(
        address owner,
        bool forceWriterRegistrationEnabled,
        address proxyAdminOwner
    )
        public
        returns (
            address balanceLedgerProxy,
            address balanceLedgerImpl,
            address proxyAdmin
        )
    {
        BalanceLedger impl = new BalanceLedger();
        balanceLedgerImpl = address(impl);

        bytes memory initData = abi.encodeCall(
            BalanceLedger.initialize,
            (owner, forceWriterRegistrationEnabled)
        );

        TransparentUpgradeableProxy transparentProxy = new TransparentUpgradeableProxy(
            balanceLedgerImpl,
            proxyAdminOwner,
            initData
        );
        balanceLedgerProxy = address(transparentProxy);

        proxyAdmin = _getProxyAdmin(balanceLedgerProxy);

        return (balanceLedgerProxy, balanceLedgerImpl, proxyAdmin);
    }

    /// @notice Get the ProxyAdmin address from a TransparentUpgradeableProxy
    /// @dev Reads the admin address from ERC1967 admin slot
    function _getProxyAdmin(address proxy) internal view returns (address) {
        bytes32 adminSlot = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
        bytes32 adminValue = vm.load(proxy, adminSlot);
        return address(uint160(uint256(adminValue)));
    }
}
