// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ISpokeDepositGateway} from "../src/interfaces/cross-chain/spoke/ISpokeDepositGateway.sol";
import {ISpokeVaultStable} from "../src/interfaces/cross-chain/spoke/ISpokeVaultStable.sol";
import {ISpokePayout} from "../src/interfaces/cross-chain/spoke/ISpokePayout.sol";

/// @title ConfigureSpokeForM5
/// @notice Spoke-side counterpart to ConfigureHubForM5. Wires LayerZero peers,
///         registers vault authorities, and registers asset classifications so
///         that:
///
///         1. The spoke gateway accepts deposits for the listed assets.
///         2. The spoke vault mirrors the same classification (required by
///            the gateway's vault forwarding logic).
///         3. The spoke gateway recognises the hub's HubIntentSettler as the
///            trusted peer at HUB_EID, so outbound LZ packets are accepted on
///            the hub side.
///         4. The spoke payout recognises the hub's WithdrawalRegistry as the
///            trusted peer at HUB_EID, so inbound LZ payout packets pass
///            authentication.
///         5. The spoke vault accepts deposit forwards from the gateway and
///            payout calls from the payout module (onlyGateway / onlyPayout).
///
/// @dev Required env vars:
///        SPOKE_GATEWAY            — SpokeDepositGateway proxy on this chain
///        SPOKE_VAULT              — SpokeVaultStable proxy on this chain
///        SPOKE_PAYOUT             — SpokePayout proxy on this chain
///        HUB_EID                  — LayerZero EID of the hub (e.g. 40231 for Arb Sepolia)
///        HUB_INTENT_SETTLER       — HubIntentSettler proxy on the hub chain
///        WITHDRAWAL_REGISTRY      — WithdrawalRegistry proxy on the hub chain
///
///      Optional env vars (comma-separated address lists):
///        BRIDGED_ASSETS           — assets to register as BRIDGED on this spoke
///        SPOKE_NATIVE_ASSETS      — assets to register as SPOKE_NATIVE on this spoke
///
/// @dev Usage:
///        forge script script/ConfigureSpokeForM5.s.sol \
///          --rpc-url $SPOKE_RPC_URL \
///          --private-key $PRIVATE_KEY \
///          --broadcast
contract ConfigureSpokeForM5 is Script {
    function run() external {
        address gatewayAddr = vm.envAddress("SPOKE_GATEWAY");
        address vaultAddr = vm.envAddress("SPOKE_VAULT");
        address payoutAddr = vm.envAddress("SPOKE_PAYOUT");
        uint32 hubEid = uint32(vm.envUint("HUB_EID"));
        address hubSettler = vm.envAddress("HUB_INTENT_SETTLER");
        address hubRegistry = vm.envAddress("WITHDRAWAL_REGISTRY");

        ISpokeDepositGateway gateway = ISpokeDepositGateway(gatewayAddr);
        ISpokeVaultStable vault = ISpokeVaultStable(vaultAddr);
        ISpokePayout payout = ISpokePayout(payoutAddr);

        bytes32 hubSettlerPeer = bytes32(uint256(uint160(hubSettler)));
        bytes32 hubRegistryPeer = bytes32(uint256(uint160(hubRegistry)));

        vm.startBroadcast();

        // --- 1. Gateway peer at HUB_EID -> HubIntentSettler -------------------
        gateway.setPeer(hubEid, hubSettlerPeer);
        console.log("Gateway: set peer at hubEid", uint256(hubEid));
        console.log("  hub settler:", hubSettler);

        // --- 2. Payout peer at HUB_EID -> WithdrawalRegistry ------------------
        payout.setPeer(hubEid, hubRegistryPeer);
        console.log("Payout: set peer at hubEid", uint256(hubEid));
        console.log("  withdrawal registry:", hubRegistry);

        // --- 3. Vault authority registration ----------------------------------
        // Without these the vault's onlyGateway / onlyPayout modifiers reject
        // every deposit and payout call. Discovered manually during M8 burn-in
        // (see docs/m8-burn-in-completion.md, bug 2).
        vault.setGateway(gatewayAddr);
        console.log("Vault: set gateway authority", gatewayAddr);
        vault.setPayout(payoutAddr);
        console.log("Vault: set payout authority", payoutAddr);

        // --- 4. Asset classifications -----------------------------------------
        _classifyAssets(gateway, vault, "BRIDGED_ASSETS", ISpokeVaultStable.AssetClassification.BRIDGED);
        _classifyAssets(gateway, vault, "SPOKE_NATIVE_ASSETS", ISpokeVaultStable.AssetClassification.SPOKE_NATIVE);

        vm.stopBroadcast();

        console.log("=== Spoke M5 Configuration Complete ===");
    }

    /// @dev Reads `envKey` as a comma-separated address list and registers
    ///      each one on both the vault and the gateway under `classification`.
    ///      Skips silently if the env var is not set or is empty.
    function _classifyAssets(
        ISpokeDepositGateway gateway,
        ISpokeVaultStable vault,
        string memory envKey,
        ISpokeVaultStable.AssetClassification classification
    ) internal {
        address[] memory assets;
        try vm.envAddress(envKey, ",") returns (address[] memory parsed) {
            assets = parsed;
        } catch {
            console.log(string.concat("Skipping ", envKey, " (not set)"));
            return;
        }

        if (assets.length == 0) {
            console.log(string.concat("Skipping ", envKey, " (empty list)"));
            return;
        }

        string memory label =
            classification == ISpokeVaultStable.AssetClassification.BRIDGED ? "BRIDGED" : "SPOKE_NATIVE";

        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];
            // Vault first — the gateway's forward path reads vault classification.
            vault.setAssetClassification(asset, classification);
            gateway.setAssetClassification(asset, classification);
            console.log(string.concat("  ", label, " asset registered:"), asset);
        }
    }
}
