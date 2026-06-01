// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console} from "forge-std/Script.sol";
import {DeployScriptBase} from "./base/DeployScriptBase.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {CollateralManager} from "../src/core/collateral/CollateralManager.sol";
import {BalanceLedger} from "../src/core/balance-ledger/BalanceLedger.sol";

/// @title DeployCollateralStack
/// @notice Deploys the CollateralManager on top of an already-deployed
///         BalanceLedger + real RiskModule, and wires the writer allowlist via
///         the testnet `forceAddWriter` fast path.
/// @dev Assumes:
///      - BalanceLedger is already deployed behind its own proxy
///      - The real RiskModule is already deployed (run-all.sh deploys it in the
///        preceding step) and its proxy address is passed in as `riskModule`
///      - `forceWriterRegistrationEnabled` was set to true at BalanceLedger init
///        (testnet only — production path uses `proposeAuthorizedWriter` + 48h
///        timelock + `executeAuthorizedWriter`)
///      - The caller of this script holds `BalanceLedger.owner()` so
///        `forceAddWriter` succeeds
///
///      Output addresses should be merged into
///      `deployments/deploy-<network>-latest.json` by the caller.
contract DeployCollateralStack is DeployScriptBase {
    /// @param owner Governance owner of the new CollateralManager
    /// @param operator Protocol settlement key allowed to call flagFor/unflagFor
    /// @param balanceLedger The already-deployed BalanceLedger proxy address
    /// @param riskModule The already-deployed RiskModule proxy the manager gates on
    /// @param proxyAdminOwner Owner of the CollateralManager's TransparentUpgradeableProxy admin
    function run(address owner, address operator, address balanceLedger, address riskModule, address proxyAdminOwner)
        external
        returns (address collateralManagerProxy, address collateralManagerImpl, address collateralManagerProxyAdmin)
    {
        vm.startBroadcast();

        // 1. Deploy the CollateralManager implementation + proxy, initialized
        //    against the real RiskModule deployed in the preceding step.
        CollateralManager mgrImpl = new CollateralManager();
        collateralManagerImpl = address(mgrImpl);

        bytes memory initData =
            abi.encodeCall(CollateralManager.initialize, (owner, operator, balanceLedger, riskModule));

        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(collateralManagerImpl, proxyAdminOwner, initData);
        collateralManagerProxy = address(proxy);
        collateralManagerProxyAdmin = _getProxyAdmin(collateralManagerProxy);

        // 2. Authorize the CollateralManager as a BalanceLedger writer via the
        //    testnet fast path. On mainnet this becomes a two-step ceremony:
        //      BalanceLedger.proposeAuthorizedWriter(mgr)
        //      (wait 48h)
        //      BalanceLedger.executeAuthorizedWriter(mgr)
        BalanceLedger(balanceLedger).forceAddWriter(collateralManagerProxy);

        vm.stopBroadcast();

        console.log("=== Collateral Stack Deployment Complete ===");
        console.log("RiskModule (wired):", riskModule);
        console.log("CollateralManager Impl:", collateralManagerImpl);
        console.log("CollateralManager Proxy:", collateralManagerProxy);
        console.log("CollateralManager ProxyAdmin:", collateralManagerProxyAdmin);
        console.log("BalanceLedger:", balanceLedger);
        console.log("Owner:", owner);
        console.log("Operator:", operator);
    }
}
