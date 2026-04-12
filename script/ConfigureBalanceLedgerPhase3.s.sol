// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {BalanceLedger} from "../src/core/balance-ledger/BalanceLedger.sol";

/// @title ConfigureBalanceLedgerPhase3
/// @notice Phase 3: Register M4 contracts (WithdrawalRegistry + HubIntentSettler)
///         as authorized writers on BalanceLedger.
/// @dev Uses forceAddWriter (testnet shortcut). MUST NOT be used on mainnet
///      where the 48h timelock path is required.
contract ConfigureBalanceLedgerPhase3 is Script {
    /// @notice Register WithdrawalRegistry and HubIntentSettler as writers.
    /// @param balanceLedger BalanceLedger proxy address
    /// @param withdrawalRegistry WithdrawalRegistry proxy address
    /// @param hubIntentSettler HubIntentSettler proxy address
    function run(
        address balanceLedger,
        address withdrawalRegistry,
        address hubIntentSettler
    ) external {
        vm.startBroadcast();

        BalanceLedger ledger = BalanceLedger(balanceLedger);

        ledger.forceAddWriter(withdrawalRegistry);
        console.log("Added writer: WithdrawalRegistry", withdrawalRegistry);

        ledger.forceAddWriter(hubIntentSettler);
        console.log("Added writer: HubIntentSettler", hubIntentSettler);

        vm.stopBroadcast();

        console.log("=== BalanceLedger Phase 3 Configuration Complete ===");
        console.log("BalanceLedger:", balanceLedger);
    }
}
