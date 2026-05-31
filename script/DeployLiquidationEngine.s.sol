// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {LiquidationEngine} from "../src/core/liquidation/LiquidationEngine.sol";
import {IBalanceLedger} from "../src/interfaces/IBalanceLedger.sol";
import {ICentuari} from "../src/interfaces/ICentuari.sol";

/// @title DeployLiquidationEngine
/// @notice Deploys the LiquidationEngine (proxy) on top of an already-deployed
///         BalanceLedger + Centuari + RiskModule + OracleRouter, authorizes it as a
///         BalanceLedger writer, and registers it on Centuari via setLiquidationEngine.
/// @dev Runs as step 14 of bin/run-all.sh, AFTER DeployRiskModule (step 13) — the
///      engine references the live RiskModule + OracleRouter. Liquidation params are
///      read from the JSON at LIQUIDATION_PARAMS_FILE (defaults to
///      script/config/liquidation-params.<NETWORK_SLUG>.json). On testnet the writer
///      add uses the force path (idempotent via isAuthorizedWriter); on mainnet it is
///      the 48h propose/execute ceremony and per-asset bonus overrides are applied via
///      governance setLiquidationBonus calls. Mirrors DeployRiskModule's broadcast +
///      _getProxyAdmin + console.log("... Proxy:" / "... ProxyAdmin:") conventions so
///      run-all.sh's parsers can capture the addresses.
contract DeployLiquidationEngine is Script {
    /// @param owner Governance owner + initial guardian (pauser) of the LiquidationEngine
    /// @param centuari Deployed Centuari proxy (debt source + liquidationRepay hook)
    /// @param balanceLedger Deployed BalanceLedger proxy (collateral seizure target)
    /// @param riskModule Deployed real RiskModule proxy (HF liquidation trigger)
    /// @param oracleRouter Deployed OracleRouter proxy (USD pricing for the seize math)
    /// @param proxyAdminOwner Owner of the new proxy's TransparentUpgradeableProxy admin
    function run(
        address owner,
        address centuari,
        address balanceLedger,
        address riskModule,
        address oracleRouter,
        address proxyAdminOwner
    ) external returns (address liquidationEngineProxy, address liquidationEngineProxyAdmin) {
        string memory paramsFile = vm.envOr(
            "LIQUIDATION_PARAMS_FILE",
            string.concat(
                vm.projectRoot(),
                "/script/config/liquidation-params.",
                vm.envOr("NETWORK_SLUG", string("arb-sepolia")),
                ".json"
            )
        );
        string memory json = vm.readFile(paramsFile);
        uint256 defaultBonusBps = vm.parseJsonUint(json, ".defaultBonusBps");
        uint256 hfCloseFactorBps = vm.parseJsonUint(json, ".hfCloseFactorBps");
        uint256 maturedCloseFactorBps = vm.parseJsonUint(json, ".maturedCloseFactorBps");

        vm.startBroadcast();

        // 1. Impl + proxy (owner is also the initial pauser until guardian handover).
        LiquidationEngine impl = new LiquidationEngine();
        bytes memory initData = abi.encodeCall(
            LiquidationEngine.initialize,
            (
                owner,
                centuari,
                balanceLedger,
                riskModule,
                oracleRouter,
                defaultBonusBps,
                hfCloseFactorBps,
                maturedCloseFactorBps,
                owner
            )
        );
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(impl), proxyAdminOwner, initData);
        liquidationEngineProxy = address(proxy);
        liquidationEngineProxyAdmin = _getProxyAdmin(liquidationEngineProxy);

        // 2. Authorize as a BalanceLedger writer (testnet force path; idempotent).
        if (!IBalanceLedger(balanceLedger).isAuthorizedWriter(liquidationEngineProxy)) {
            IBalanceLedger(balanceLedger).forceAddWriter(liquidationEngineProxy);
        }

        // 3. Register on Centuari so liquidationRepay accepts the engine.
        ICentuari(centuari).setLiquidationEngine(liquidationEngineProxy);

        vm.stopBroadcast();

        console.log("=== LiquidationEngine Deployment Complete ===");
        console.log("LiquidationEngine Proxy:", liquidationEngineProxy);
        console.log("LiquidationEngine ProxyAdmin:", liquidationEngineProxyAdmin);
        console.log("Owner:", owner);
    }

    /// @notice Read the ProxyAdmin address from a TransparentUpgradeableProxy
    function _getProxyAdmin(address proxy) internal view returns (address) {
        bytes32 adminSlot = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
        bytes32 adminValue = vm.load(proxy, adminSlot);
        return address(uint160(uint256(adminValue)));
    }
}
