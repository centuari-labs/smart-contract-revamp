// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console} from "forge-std/Script.sol";
import {DeployScriptBase} from "./base/DeployScriptBase.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {WithdrawalRegistry} from "../src/core/cross-chain/WithdrawalRegistry.sol";
import {HubIntentSettler} from "../src/core/cross-chain/HubIntentSettler.sol";
import {SettlementLedger} from "../src/core/cross-chain/SettlementLedger.sol";
import {BalanceLedger} from "../src/core/balance-ledger/BalanceLedger.sol";
import {HubDepositor} from "../src/core/cross-chain/HubDepositor.sol";

/// @title DeployCrossChainHub
/// @notice Deploys all three M4 cross-chain hub contracts behind proxies and
///         wires the circular dependency between HubIntentSettler ↔ SettlementLedger.
/// @dev Deploy order:
///      1. WithdrawalRegistry (no cross-dependencies among M4 contracts)
///      2. HubIntentSettler (needs BalanceLedger only at init)
///      3. SettlementLedger (needs HubIntentSettler address)
///      4. Wire: HubIntentSettler.setSettlementLedger(settlementLedger)
contract DeployCrossChainHub is DeployScriptBase {
    /// @notice Deploy all M4 cross-chain hub contracts.
    /// @param owner Governance owner for all contracts
    /// @param operator Backend operator / settlement key
    /// @param balanceLedger BalanceLedger proxy address
    /// @param riskModule RiskModule (stub or real) address
    /// @param hubDepositor HubDepositor proxy address
    /// @param proxyAdminOwner Owner of the ProxyAdmin (e.g. multisig)
    function run(
        address owner,
        address operator,
        address balanceLedger,
        address riskModule,
        address hubDepositor,
        address proxyAdminOwner
    ) external {
        vm.startBroadcast();

        // 1. WithdrawalRegistry
        WithdrawalRegistry wrImpl = new WithdrawalRegistry();
        bytes memory wrInit =
            abi.encodeCall(WithdrawalRegistry.initialize, (owner, operator, balanceLedger, riskModule, hubDepositor));
        TransparentUpgradeableProxy wrProxy = new TransparentUpgradeableProxy(address(wrImpl), proxyAdminOwner, wrInit);

        // 2. HubIntentSettler
        HubIntentSettler hisImpl = new HubIntentSettler();
        bytes memory hisInit = abi.encodeCall(HubIntentSettler.initialize, (owner, operator, balanceLedger));
        TransparentUpgradeableProxy hisProxy =
            new TransparentUpgradeableProxy(address(hisImpl), proxyAdminOwner, hisInit);

        // 3. SettlementLedger
        SettlementLedger slImpl = new SettlementLedger();
        bytes memory slInit = abi.encodeCall(SettlementLedger.initialize, (owner, operator, address(hisProxy)));
        TransparentUpgradeableProxy slProxy = new TransparentUpgradeableProxy(address(slImpl), proxyAdminOwner, slInit);

        // 4. Wire circular dependency
        HubIntentSettler(address(hisProxy)).setSettlementLedger(address(slProxy));

        // 5. Register WithdrawalRegistry + HubIntentSettler as BalanceLedger writers
        //    (folded from ConfigureBalanceLedgerPhase3). Testnet forceAddWriter, guarded.
        if (!BalanceLedger(balanceLedger).isAuthorizedWriter(address(wrProxy))) {
            BalanceLedger(balanceLedger).forceAddWriter(address(wrProxy));
            console.log("Added writer: WithdrawalRegistry", address(wrProxy));
        }
        if (!BalanceLedger(balanceLedger).isAuthorizedWriter(address(hisProxy))) {
            BalanceLedger(balanceLedger).forceAddWriter(address(hisProxy));
            console.log("Added writer: HubIntentSettler", address(hisProxy));
        }

        // 6. Authorize WithdrawalRegistry to call HubDepositor.payoutDirect
        //    (folded from ConfigureHubDepositorAuth).
        HubDepositor(hubDepositor).setAuthorizedCaller(address(wrProxy), true);
        console.log("Authorized caller on HubDepositor: WithdrawalRegistry", address(wrProxy));

        vm.stopBroadcast();

        console.log("=== M4 Cross-Chain Hub Deployment Complete ===");
        console.log("WithdrawalRegistry implementation:", address(wrImpl));
        console.log("WithdrawalRegistry proxy:", address(wrProxy));
        console.log("WithdrawalRegistry ProxyAdmin:", _getProxyAdmin(address(wrProxy)));
        console.log("HubIntentSettler implementation:", address(hisImpl));
        console.log("HubIntentSettler proxy:", address(hisProxy));
        console.log("HubIntentSettler ProxyAdmin:", _getProxyAdmin(address(hisProxy)));
        console.log("SettlementLedger implementation:", address(slImpl));
        console.log("SettlementLedger proxy:", address(slProxy));
        console.log("SettlementLedger ProxyAdmin:", _getProxyAdmin(address(slProxy)));
        console.log("Owner:", owner);
        console.log("Operator:", operator);
    }
}
