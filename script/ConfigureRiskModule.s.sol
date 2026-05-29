// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

import {RiskModule} from "../src/core/risk/RiskModule.sol";
import {OracleRouter} from "../src/core/oracle/OracleRouter.sol";
import {CollateralManager} from "../src/core/collateral/CollateralManager.sol";
import {WithdrawalRegistry} from "../src/core/cross-chain/WithdrawalRegistry.sol";

/// @title ConfigureRiskModule
/// @notice Track B3 / C6 Phase 2: configure the freshly-deployed real RiskModule +
///         OracleRouter from a committed risk-params JSON, then (optionally) swap the
///         real module into WithdrawalRegistry + CollateralManager.
/// @dev Reads two JSON files, paths via env:
///        RISK_PARAMS_FILE — { defaultBufferBps, assets: { SYM: { ltvBps, maxStalenessSeconds, bufferBps? } } }
///        DEPLOY_JSON      — the run-all.sh deployment summary (for `mockTokens`: SYM -> address)
///      The broadcaster must hold `owner()` on RiskModule, OracleRouter, CollateralManager
///      and WithdrawalRegistry — i.e. the deployer key run-all.sh signs with.
///
///      Price-pushing is intentionally NOT done here: `PushOracle.setPrice` is
///      operator-gated (a different key) and is the job of the Phase 3 price keeper.
///      A freshly-configured oracle therefore has no price yet and fail-closes, so
///      collateral withdraw/unflag-while-in-debt are blocked (safe) until the keeper
///      pushes — non-collateral and debt-free paths are unaffected, which is why the
///      `setRiskModule` swap below is safe to run before prices land.
contract ConfigureRiskModule is Script {
    function run(
        address riskModule,
        address oracleRouter,
        address collateralManager,
        address withdrawalRegistry,
        bool doSwap
    ) external {
        string memory params = vm.readFile(vm.envString("RISK_PARAMS_FILE"));
        string memory deploy = vm.readFile(vm.envString("DEPLOY_JSON"));

        uint256 defaultBufferBps = vm.parseJsonUint(params, ".defaultBufferBps");
        string[] memory symbols = vm.parseJsonKeys(params, ".assets");

        vm.startBroadcast();

        RiskModule(riskModule).setDefaultBuffer(defaultBufferBps);

        for (uint256 i = 0; i < symbols.length; ++i) {
            string memory sym = symbols[i];
            string memory tokenKey = string.concat(".mockTokens.", sym);

            // Only configure assets that were actually deployed in this run.
            if (!vm.keyExistsJson(deploy, tokenKey)) {
                console.log("skip (token not in deployment):", sym);
                continue;
            }
            address asset = vm.parseJsonAddress(deploy, tokenKey);

            uint256 ltvBps = vm.parseJsonUint(params, string.concat(".assets.", sym, ".ltvBps"));
            uint256 staleness = vm.parseJsonUint(params, string.concat(".assets.", sym, ".maxStalenessSeconds"));

            RiskModule(riskModule).setLtv(asset, ltvBps);
            OracleRouter(oracleRouter).setMaxStaleness(asset, staleness);

            // Optional per-asset HF buffer override (else the default applies).
            string memory bufKey = string.concat(".assets.", sym, ".bufferBps");
            if (vm.keyExistsJson(params, bufKey)) {
                RiskModule(riskModule).setBuffer(asset, vm.parseJsonUint(params, bufKey));
            }

            console.log("configured", sym, asset);
        }

        if (doSwap) {
            CollateralManager(collateralManager).setRiskModule(riskModule);
            WithdrawalRegistry(withdrawalRegistry).setRiskModule(riskModule);
            console.log("setRiskModule(real) on CollateralManager + WithdrawalRegistry");
        } else {
            console.log("Swap SKIPPED (SKIP_RISK_MODULE_SWAP=1) - stub stays wired; run the swap manually when ready");
        }

        vm.stopBroadcast();

        console.log("=== ConfigureRiskModule complete ===");
        console.log("RiskModule:", riskModule);
        console.log("OracleRouter:", oracleRouter);
        console.log("Swapped:", doSwap);
    }
}
