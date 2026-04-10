// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {BalanceLedger} from "../src/core/balance-ledger/BalanceLedger.sol";

/// @title ConfigureBalanceLedger
/// @notice Script to register authorized writers on BalanceLedger via forceAddWriter.
/// @dev Two-phase configuration:
///      Phase 1: called after Centuari + HubDepositor are deployed but before Settlement.
///               CollateralManager is NOT included here — DeployCollateralStack already
///               registers it as a writer during its own deployment.
///      Phase 2: called after Settlement is deployed to add it as a writer.
///      Both phases use forceAddWriter (testnet shortcut). MUST NOT be used on mainnet
///      where the 48h timelock path (proposeAuthorizedWriter → executeAuthorizedWriter)
///      is required.
contract ConfigureBalanceLedger is Script {
    /// @notice Phase 1: Register Centuari and HubDepositor as writers.
    /// @dev CollateralManager is excluded — DeployCollateralStack already registers
    ///      it via forceAddWriter during its deployment. Adding it here would revert
    ///      with WriterAlreadyAuthorized.
    /// @param balanceLedger BalanceLedger proxy address
    /// @param centuari Centuari proxy address
    /// @param hubDepositor HubDepositor proxy address
    function run(
        address balanceLedger,
        address centuari,
        address hubDepositor
    ) external {
        vm.startBroadcast();

        BalanceLedger ledger = BalanceLedger(balanceLedger);

        ledger.forceAddWriter(centuari);
        console.log("Added writer: Centuari", centuari);

        ledger.forceAddWriter(hubDepositor);
        console.log("Added writer: HubDepositor", hubDepositor);

        vm.stopBroadcast();

        console.log("=== BalanceLedger Phase 1 Configuration Complete ===");
        console.log("BalanceLedger:", balanceLedger);
    }

    /// @notice Phase 2: Register Settlement as a writer (called after DeploySettlement).
    /// @param balanceLedger BalanceLedger proxy address
    /// @param settlement Settlement proxy address
    function addSettlement(address balanceLedger, address settlement) external {
        vm.startBroadcast();

        BalanceLedger(balanceLedger).forceAddWriter(settlement);

        vm.stopBroadcast();

        console.log("=== BalanceLedger Phase 2 Configuration Complete ===");
        console.log("BalanceLedger:", balanceLedger);
        console.log("Added writer: Settlement", settlement);
    }
}
