// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {HubIntentSettler} from "../src/core/cross-chain/HubIntentSettler.sol";
import {WithdrawalRegistry} from "../src/core/cross-chain/WithdrawalRegistry.sol";

/// @title ConfigureHubForM5
/// @notice Post-deployment hub-side wiring for M5 spoke contracts. Run on the
///         hub chain (Arbitrum) after:
///         1. Spoke contracts are deployed on each spoke chain via
///            `DeploySpokeContracts.s.sol`.
///         2. Hub contracts are already deployed via `bin/run-all.sh` steps 16–18.
/// @dev Reads env vars for all addresses. Example invocation:
///      ```
///      HUB_INTENT_SETTLER=0x... WITHDRAWAL_REGISTRY=0x... \
///      LZ_ENDPOINT=0x... SPOKE_GATEWAY_BASE=0x... SPOKE_PAYOUT_BASE=0x... \
///      forge script script/ConfigureHubForM5.s.sol \
///        --rpc-url $ARB_SEPOLIA_RPC --broadcast
///      ```
contract ConfigureHubForM5 is Script {
    function run() external {
        address settlerAddr = vm.envAddress("HUB_INTENT_SETTLER");
        address registryAddr = vm.envAddress("WITHDRAWAL_REGISTRY");
        address lzEndpoint = vm.envAddress("LZ_ENDPOINT");

        HubIntentSettler settler = HubIntentSettler(settlerAddr);
        WithdrawalRegistry registry = WithdrawalRegistry(registryAddr);

        vm.startBroadcast();

        // ---- HubIntentSettler: LZ endpoint + trusted remotes ----
        settler.setLzEndpoint(lzEndpoint);
        settler.setWithdrawalRegistry(registryAddr);
        console.log("Settler: LZ endpoint set to", lzEndpoint);
        console.log("Settler: WithdrawalRegistry set to", registryAddr);

        // Register each spoke gateway as a trusted remote.
        // Env format: SPOKE_GATEWAY_<CHAIN> and SPOKE_EID_<CHAIN>
        _registerSpokeIfSet(settler, "BASE");
        _registerSpokeIfSet(settler, "ETH");
        _registerSpokeIfSet(settler, "BNB");
        _registerSpokeIfSet(settler, "POLYGON");

        // ---- WithdrawalRegistry: LZ payout dispatch wiring ----
        registry.setPayoutEndpoint(lzEndpoint);
        registry.setHubIntentSettler(settlerAddr);
        console.log("Registry: payout endpoint set to", lzEndpoint);
        console.log("Registry: HubIntentSettler set to", settlerAddr);

        // Register payout peers + spoke eids.
        _registerPayoutIfSet(registry, "BASE");
        _registerPayoutIfSet(registry, "ETH");
        _registerPayoutIfSet(registry, "BNB");
        _registerPayoutIfSet(registry, "POLYGON");

        // ---- Spoke-native routes ----
        // Register known spoke-native (asset, chainId) pairs from the matrix.
        // These env vars are optional; skip silently if not set.
        _registerSpokeNativeRouteIfSet(registry, "XSGD", "BASE");
        _registerSpokeNativeRouteIfSet(registry, "IDRX", "POLYGON");

        vm.stopBroadcast();

        console.log("=== Hub M5 Configuration Complete ===");
    }

    function _registerSpokeIfSet(HubIntentSettler settler, string memory chain) internal {
        string memory gatewayKey = string.concat("SPOKE_GATEWAY_", chain);
        string memory eidKey = string.concat("SPOKE_EID_", chain);

        try vm.envAddress(gatewayKey) returns (address gateway) {
            uint32 eid = uint32(vm.envUint(eidKey));
            bytes32 peer = bytes32(uint256(uint160(gateway)));
            settler.setTrustedRemote(eid, peer);
            console.log(string.concat("Settler: trusted remote ", chain, " ->"), gateway);
        } catch {
            // Env not set — skip this chain.
        }
    }

    function _registerPayoutIfSet(WithdrawalRegistry registry, string memory chain) internal {
        string memory payoutKey = string.concat("SPOKE_PAYOUT_", chain);
        string memory eidKey = string.concat("SPOKE_EID_", chain);
        string memory chainIdKey = string.concat("SPOKE_CHAIN_ID_", chain);

        try vm.envAddress(payoutKey) returns (address payoutAddr) {
            uint32 eid = uint32(vm.envUint(eidKey));
            uint256 chainId = vm.envUint(chainIdKey);
            bytes32 peer = bytes32(uint256(uint160(payoutAddr)));
            registry.setPayoutPeer(eid, peer);
            registry.setSpokeEid(chainId, eid);
            console.log(string.concat("Registry: payout peer ", chain, " ->"), payoutAddr);
        } catch {
            // Env not set — skip this chain.
        }
    }

    function _registerSpokeNativeRouteIfSet(WithdrawalRegistry registry, string memory token, string memory chain)
        internal
    {
        string memory assetKey = string.concat("SPOKE_NATIVE_ASSET_", token, "_", chain);
        string memory chainIdKey = string.concat("SPOKE_CHAIN_ID_", chain);

        try vm.envAddress(assetKey) returns (address asset) {
            uint256 chainId = vm.envUint(chainIdKey);
            registry.setSpokeNativeRoute(asset, chainId, true);
            console.log(string.concat("Registry: spoke-native route ", token, "/", chain, " ->"), asset);
        } catch {
            // Env not set — skip.
        }
    }
}
