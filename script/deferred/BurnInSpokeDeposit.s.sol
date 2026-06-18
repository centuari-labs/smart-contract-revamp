// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ISpokeDepositGateway} from "../../src/interfaces/cross-chain/spoke/ISpokeDepositGateway.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title BurnInSpokeDeposit
/// @notice One-shot script that triggers an end-to-end M8 burn-in deposit on
///         a chosen spoke chain. Approves the gateway for `amount` of the
///         asset, quotes the LayerZero native fee, then calls
///         `gateway.deposit{value: fee}(asset, amount)`.
///
///         The deposit emits `DepositInitiated` on the spoke (consumed by
///         indexer-v3 spoke-deposit-gateway processor → seeds
///         cross_chain_deposit row with state=INITIATED). LayerZero V2 then
///         relays the message to the hub, where HubIntentSettler.confirmDeposit
///         emits DepositConfirmed (consumed by indexer-v3 hub-intent-settler
///         processor → flips the same row to state=CREDITED, and
///         BalanceLedger.Credited is also indexed → user_balance.available
///         reflects the credit).
///
/// @dev Required env vars:
///        SPOKE_GATEWAY     — SpokeDepositGateway proxy on the spoke chain
///        BURN_IN_ASSET     — ERC20 token address (BRIDGED, must be classified)
///        BURN_IN_AMOUNT    — units in the token's smallest denomination
///                            (e.g. 1000000 = 1 USDC at 6 decimals)
///
/// @dev Usage:
///        forge script script/deferred/BurnInSpokeDeposit.s.sol \
///          --rpc-url $SPOKE_RPC_URL \
///          --private-key $PRIVATE_KEY \
///          --broadcast --skip-simulation
contract BurnInSpokeDeposit is Script {
    function run() external {
        address gatewayAddr = vm.envAddress("SPOKE_GATEWAY");
        address asset = vm.envAddress("BURN_IN_ASSET");
        uint256 amount = vm.envUint("BURN_IN_AMOUNT");

        ISpokeDepositGateway gateway = ISpokeDepositGateway(gatewayAddr);
        IERC20 token = IERC20(asset);

        console.log("=== Burn-In Spoke Deposit ===");
        console.log("Gateway:", gatewayAddr);
        console.log("Asset:  ", asset);
        console.log("Amount: ", amount);

        // Pre-flight: caller balance + classification check (read-only).
        uint256 balBefore = token.balanceOf(msg.sender);
        console.log("Caller token balance:", balBefore);
        require(balBefore >= amount, "BurnInSpokeDeposit: insufficient token balance");

        // Quote LZ fee BEFORE broadcast so we can include msg.value.
        uint256 nativeFee = gateway.quoteDeposit(asset, amount);
        console.log("LZ native fee (wei):", nativeFee);

        vm.startBroadcast();

        // 1. approve gateway to pull the tokens
        token.approve(gatewayAddr, amount);
        console.log("Approved gateway for amount.");

        // 2. trigger the deposit (msg.value covers LZ native fee)
        bytes32 depositId = gateway.deposit{value: nativeFee}(asset, amount);

        vm.stopBroadcast();

        console.log("=== DepositInitiated ===");
        console.logBytes32(depositId);
        console.log("");
        console.log("Watch indexer-v3 logs and:");
        console.log("  1. cross_chain_deposit row appears with state=INITIATED");
        console.log("  2. After LayerZero relay (~30s-2min on testnet),");
        console.log("     HubIntentSettler.DepositConfirmed fires on hub,");
        console.log("     row transitions to state=CREDITED.");
        console.log("  3. BalanceLedger.Credited also fires; user_balance.available updates.");
    }
}
