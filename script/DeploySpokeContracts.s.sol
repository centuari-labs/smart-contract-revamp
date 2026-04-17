// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {SpokeVaultStable} from "../src/core/cross-chain/spoke/SpokeVaultStable.sol";
import {SpokePayout} from "../src/core/cross-chain/spoke/SpokePayout.sol";
import {SpokeDepositGateway} from "../src/core/cross-chain/spoke/SpokeDepositGateway.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @title DeploySpokeContracts
/// @notice Deployment script for the three M5 spoke contracts on a spoke
///         chain (Base, Ethereum, BNB, Polygon). Deploys each behind a
///         TransparentUpgradeableProxy in the correct order:
///         SpokeVaultStable → SpokePayout → SpokeDepositGateway.
/// @dev Usage:
///      ```
///      forge script script/DeploySpokeContracts.s.sol \
///        --sig 'run(address,address,uint32,address)' \
///        $OWNER $LZ_ENDPOINT $HUB_EID $PROXY_ADMIN_OWNER \
///        --rpc-url $SPOKE_RPC --broadcast --verify
///      ```
///      After deployment, run ConfigureHubForM5.s.sol on the hub chain to
///      register the spoke contracts as trusted remotes / payout peers.
contract DeploySpokeContracts is Script {
    /// @notice Deploy all three spoke contracts.
    /// @param owner Governance / multisig owner for all three contracts
    /// @param lzEndpoint LayerZero V2 endpoint on this spoke chain
    /// @param hubEid LayerZero endpoint id of the hub (Arbitrum)
    /// @param proxyAdminOwner Owner of each ProxyAdmin (e.g. multisig)
    function run(
        address owner,
        address lzEndpoint,
        uint32 hubEid,
        address proxyAdminOwner
    ) external {
        vm.startBroadcast();

        // 1. SpokeVaultStable
        (
            address vaultProxy,
            address vaultImpl,
            address vaultProxyAdmin
        ) = _deployVault(owner, proxyAdminOwner);

        // 2. SpokePayout
        (
            address payoutProxy,
            address payoutImpl,
            address payoutProxyAdmin
        ) = _deployPayout(owner, vaultProxy, lzEndpoint, proxyAdminOwner);

        // 3. SpokeDepositGateway
        (
            address gatewayProxy,
            address gatewayImpl,
            address gatewayProxyAdmin
        ) = _deployGateway(
                owner,
                vaultProxy,
                lzEndpoint,
                hubEid,
                proxyAdminOwner
            );

        vm.stopBroadcast();

        console.log("=== Spoke Deployment Complete ===");
        console.log("SpokeVaultStable implementation:", vaultImpl);
        console.log("SpokeVaultStable proxy:", vaultProxy);
        console.log("SpokeVaultStable ProxyAdmin:", vaultProxyAdmin);
        console.log("SpokePayout implementation:", payoutImpl);
        console.log("SpokePayout proxy:", payoutProxy);
        console.log("SpokePayout ProxyAdmin:", payoutProxyAdmin);
        console.log("SpokeDepositGateway implementation:", gatewayImpl);
        console.log("SpokeDepositGateway proxy:", gatewayProxy);
        console.log("SpokeDepositGateway ProxyAdmin:", gatewayProxyAdmin);
        console.log("Owner:", owner);
        console.log("LZ Endpoint:", lzEndpoint);
        console.log("Hub EID:", uint256(hubEid));
        console.log("ProxyAdmin Owner:", proxyAdminOwner);
    }

    function _deployVault(
        address owner,
        address proxyAdminOwner
    )
        internal
        returns (address proxy, address impl, address proxyAdmin)
    {
        SpokeVaultStable implContract = new SpokeVaultStable();
        impl = address(implContract);

        bytes memory initData = abi.encodeCall(
            SpokeVaultStable.initialize,
            (owner)
        );

        TransparentUpgradeableProxy transparentProxy = new TransparentUpgradeableProxy(
            impl,
            proxyAdminOwner,
            initData
        );
        proxy = address(transparentProxy);
        proxyAdmin = _getProxyAdmin(proxy);
    }

    function _deployPayout(
        address owner,
        address vault,
        address lzEndpoint,
        address proxyAdminOwner
    )
        internal
        returns (address proxy, address impl, address proxyAdmin)
    {
        SpokePayout implContract = new SpokePayout();
        impl = address(implContract);

        bytes memory initData = abi.encodeCall(
            SpokePayout.initialize,
            (owner, vault, lzEndpoint)
        );

        TransparentUpgradeableProxy transparentProxy = new TransparentUpgradeableProxy(
            impl,
            proxyAdminOwner,
            initData
        );
        proxy = address(transparentProxy);
        proxyAdmin = _getProxyAdmin(proxy);
    }

    function _deployGateway(
        address owner,
        address vault,
        address lzEndpoint,
        uint32 hubEid,
        address proxyAdminOwner
    )
        internal
        returns (address proxy, address impl, address proxyAdmin)
    {
        SpokeDepositGateway implContract = new SpokeDepositGateway();
        impl = address(implContract);

        bytes memory initData = abi.encodeCall(
            SpokeDepositGateway.initialize,
            (owner, vault, lzEndpoint, hubEid)
        );

        TransparentUpgradeableProxy transparentProxy = new TransparentUpgradeableProxy(
            impl,
            proxyAdminOwner,
            initData
        );
        proxy = address(transparentProxy);
        proxyAdmin = _getProxyAdmin(proxy);
    }

    /// @notice Get the ProxyAdmin address from a TransparentUpgradeableProxy
    function _getProxyAdmin(address proxy) internal view returns (address) {
        bytes32 adminSlot = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
        bytes32 adminValue = vm.load(proxy, adminSlot);
        return address(uint160(uint256(adminValue)));
    }
}
