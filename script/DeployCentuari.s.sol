// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {Centuari} from "../src/core/centuari/Centuari.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @title DeployCentuari
/// @notice Deployment script for Centuari (implementation + TransparentUpgradeableProxy).
/// @dev Pass the Treasury address from DeployTreasury. After this, run DeployTreasury.run(treasury, centuariProxy)
///      to call setCentuariContract on Treasury. Use settlementPlaceholder = owner when deploying before
///      Settlement; then deploy Settlement with this proxy and call Centuari.setSettlement(settlementProxy).
contract DeployCentuari is Script {
    /// @notice Deploy Centuari (impl + proxy). Then run DeployTreasury.run(treasury, centuariProxy) to set Centuari on Treasury.
    /// @param owner Centuari owner
    /// @param settlementPlaceholder Address for Centuari.initialize settlement_ (use owner if Settlement not yet deployed)
    /// @param treasury Treasury contract address (from DeployTreasury)
    /// @param proxyAdminOwner Owner of the ProxyAdmin (e.g. multisig)
    /// @return centuariProxy Centuari proxy address (use as CENTUARI_ADDRESS for DeploySettlement)
    /// @return centuariImpl Centuari implementation address
    /// @return proxyAdmin ProxyAdmin address
    function run(
        address owner,
        address settlementPlaceholder,
        address treasury,
        address proxyAdminOwner
    )
        external
        returns (
            address centuariProxy,
            address centuariImpl,
            address proxyAdmin
        )
    {
        vm.startBroadcast();

        (centuariProxy, centuariImpl, proxyAdmin) = deploy(
            owner,
            settlementPlaceholder,
            treasury,
            proxyAdminOwner
        );

        vm.stopBroadcast();

        console.log("=== Centuari Deployment Complete ===");
        console.log("Centuari implementation:", centuariImpl);
        console.log("Centuari proxy:", centuariProxy);
        console.log("ProxyAdmin:", proxyAdmin);
        console.log("Owner:", owner);
        console.log("Settlement placeholder:", settlementPlaceholder);
        console.log("Treasury:", treasury);
        console.log("ProxyAdmin Owner:", proxyAdminOwner);

        return (centuariProxy, centuariImpl, proxyAdmin);
    }

    /// @notice Deploy Centuari impl + proxy (no setCentuariContract; use DeployTreasury.run(treasury, centuariProxy) after).
    /// @param owner Centuari owner
    /// @param settlementPlaceholder Address for Centuari.initialize settlement_
    /// @param treasury Treasury contract address
    /// @param proxyAdminOwner Owner of the ProxyAdmin
    function deploy(
        address owner,
        address settlementPlaceholder,
        address treasury,
        address proxyAdminOwner
    )
        public
        returns (
            address centuariProxy,
            address centuariImpl,
            address proxyAdmin
        )
    {
        Centuari centuariImplContract = new Centuari();
        centuariImpl = address(centuariImplContract);

        bytes memory initData = abi.encodeCall(
            Centuari.initialize,
            (owner, settlementPlaceholder, treasury)
        );

        TransparentUpgradeableProxy transparentProxy = new TransparentUpgradeableProxy(
            centuariImpl,
            proxyAdminOwner,
            initData
        );
        centuariProxy = address(transparentProxy);

        proxyAdmin = _getProxyAdmin(centuariProxy);

        return (centuariProxy, centuariImpl, proxyAdmin);
    }

    /// @notice Get the ProxyAdmin address from a TransparentUpgradeableProxy
    /// @dev Reads the admin address from ERC1967 admin slot
    function _getProxyAdmin(address proxy) internal view returns (address) {
        bytes32 adminSlot = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
        bytes32 adminValue = vm.load(proxy, adminSlot);
        return address(uint160(uint256(adminValue)));
    }
}
