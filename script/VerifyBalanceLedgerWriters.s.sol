// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IBalanceLedger} from "../src/interfaces/IBalanceLedger.sol";

/// @title VerifyBalanceLedgerWriters
/// @notice Post-deploy assertion that BalanceLedger's authorized-writer set is
///         EXACTLY the intended contracts — no more, no fewer-than-required.
/// @dev Audit finding M-1: `markCollateral` / `unmarkCollateral` (the on-chain
///      `usedAsCollateral` flag) share a single `onlyAuthorizedWriter` gate with
///      `credit` / `debit`. There is no per-function role split, so ANY authorized
///      writer can flag/unflag ANY user's collateral. The safety of the collateral
///      model therefore rests entirely on the writer set being exactly the intended
///      contracts. This script makes that invariant explicit and machine-checked
///      instead of implicit in deploy-script ordering.
///
///      Run (view-only, no broadcast):
///        DEPLOY_SUMMARY_FILE=deployments/deploy-arb-sepolia-latest.json \
///          forge script script/VerifyBalanceLedgerWriters.s.sol --sig "run()"
///
///      On mainnet set REQUIRE_FORCE_DISABLED=1 so the run also asserts that the
///      testnet `forceAddWriter` fast path is permanently off (a true value would
///      let the owner instantly add a writer with no 48h timelock).
///
///      Limitation: BalanceLedger exposes no writer enumeration, so "no UNEXPECTED
///      writer exists" cannot be fully proven on-chain. This asserts (a) every
///      intended contract IS a writer, (b) the deployer EOA is NOT (the most common
///      footgun), and (c) force-registration is disabled when required.
contract VerifyBalanceLedgerWriters is Script {
    function run() external view {
        string memory file = vm.envOr(
            "DEPLOY_SUMMARY_FILE",
            string.concat(
                vm.projectRoot(),
                "/deployments/deploy-",
                vm.envOr("NETWORK_SLUG", string("arb-sepolia")),
                "-latest.json"
            )
        );
        string memory json = vm.readFile(file);

        IBalanceLedger bl = IBalanceLedger(vm.parseJsonAddress(json, ".balanceLedgerAddress"));

        // The exact intended writer set (see smart-contract-revamp/CLAUDE.md
        // "Deployment Rules" — writer registration is folded into these scripts).
        string[7] memory keys = [
            ".centuariAddress",
            ".settlementProxy",
            ".hubDepositorAddress",
            ".collateralManagerAddress",
            ".withdrawalRegistryAddress",
            ".hubIntentSettlerAddress",
            ".liquidationEngineAddress"
        ];
        string[7] memory names = [
            "Centuari",
            "Settlement",
            "HubDepositor",
            "CollateralManager",
            "WithdrawalRegistry",
            "HubIntentSettler",
            "LiquidationEngine"
        ];

        console.log("=== BalanceLedger writer-set verification ===");
        console.log("BalanceLedger:", address(bl));

        for (uint256 i = 0; i < keys.length; ++i) {
            // LiquidationEngine is optional (SKIP_LIQUIDATION deploys omit it).
            if (!vm.keyExistsJson(json, keys[i])) {
                console.log("  (absent in summary, skipped):", names[i]);
                continue;
            }
            address writer = vm.parseJsonAddress(json, keys[i]);
            if (writer == address(0)) {
                console.log("  (zero address, skipped):", names[i]);
                continue;
            }
            bool ok = bl.isAuthorizedWriter(writer);
            console.log(ok ? "  [writer]   " : "  [MISSING]  ", names[i], writer);
            require(ok, string.concat("BalanceLedger: expected writer not authorized: ", names[i]));
        }

        // The deployer EOA must never retain writer power.
        address deployer = vm.parseJsonAddress(json, ".deployer");
        bool deployerIsWriter = bl.isAuthorizedWriter(deployer);
        console.log(deployerIsWriter ? "  [DEPLOYER IS WRITER!]" : "  [deployer not a writer]", deployer);
        require(!deployerIsWriter, "BalanceLedger: deployer EOA is an authorized writer");

        // Mainnet: the testnet force-add fast path must be permanently disabled.
        bool forceEnabled = bl.forceWriterRegistrationEnabled();
        console.log("forceWriterRegistrationEnabled:", forceEnabled);
        if (vm.envOr("REQUIRE_FORCE_DISABLED", uint256(0)) == 1) {
            require(!forceEnabled, "BalanceLedger: forceWriterRegistrationEnabled must be false on mainnet");
        }

        console.log("=== writer-set verification PASSED ===");
    }
}
