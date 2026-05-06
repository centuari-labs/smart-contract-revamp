// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {Settlement} from "../src/core/settlement/Settlement.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @title DeploySettlement
/// @notice Deployment script for Settlement contract with TransparentUpgradeableProxy
/// @dev Deploys:
///      1. Settlement implementation
///      2. ProxyAdmin (controlled by deployer/multisig)
///      3. TransparentUpgradeableProxy with implementation and admin
///      4. Initializes Settlement via proxy
contract DeploySettlement is Script {
    /// @notice Main deployment function
    /// @param owner The owner address for the Settlement contract
    /// @param operator The settlement engine operator address
    /// @param centuari The Centuari contract address
    /// @param proxyAdminOwner The owner of the ProxyAdmin (typically a multisig)
    /// @return proxy The deployed proxy address
    /// @return proxyAdmin The deployed ProxyAdmin address
    /// @return implementation The deployed implementation address
    function run(address owner, address operator, address centuari, address proxyAdminOwner)
        external
        returns (address proxy, address proxyAdmin, address implementation)
    {
        vm.startBroadcast();

        (proxy, proxyAdmin, implementation) = deploy(owner, operator, centuari, proxyAdminOwner);

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

    /// @notice Get the ProxyAdmin address from a TransparentUpgradeableProxy
    /// @dev Reads the admin address from ERC1967 admin slot
    /// @param proxy The proxy address
    /// @return The ProxyAdmin address
    function _getProxyAdmin(address proxy) internal view returns (address) {
        // ERC1967 admin slot: bytes32(uint256(keccak256('eip1967.proxy.admin')) - 1)
        bytes32 adminSlot = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
        bytes32 adminValue = vm.load(proxy, adminSlot);
        return address(uint160(uint256(adminValue)));
    }
}
