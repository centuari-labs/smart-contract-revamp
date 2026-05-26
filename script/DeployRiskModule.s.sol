// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {OracleRouter} from "../src/core/oracle/OracleRouter.sol";
import {RiskModule} from "../src/core/risk/RiskModule.sol";
import {PushOracle} from "../src/core/oracle/PushOracle.sol";

/// @title DeployRiskModule
/// @notice Deploys the Phase 3 (C6) oracle + real RiskModule stack on top of an
///         already-deployed BalanceLedger + Centuari.
/// @dev Provider-agnostic oracle: `OracleRouter` (upgradeable) routes each asset
///      to an `IPriceFeed`. This script deploys the router + the real RiskModule
///      behind proxies, and a `PushOracle` per supplied RWA/synthetic asset
///      (registered via `setFeed`). Chainlink-backed assets get a
///      `ChainlinkPriceFeed` adapter registered separately once the live feed
///      addresses are known, and per-asset LTV / buffer / staleness are
///      configured by governance from the off-chain risk table — both are
///      operator/governance config steps, not baked into deploy.
///
///      Assumes (like `DeployCollateralStack.s.sol`) the broadcaster holds
///      `owner` privileges so `OracleRouter.setFeed` succeeds for the PushOracles.
///
///      The Phase 4 governance swap — `setRiskModule(riskModuleProxy)` on BOTH
///      `WithdrawalRegistry` and `CollateralManager` — is intentionally NOT done
///      here; it is gated on audit. Output addresses should be merged into
///      `deployments/deploy-<network>-latest.json`.
contract DeployRiskModule is Script {
    /// @param owner Governance owner of the OracleRouter + RiskModule
    /// @param operator Price-pushing operator for the PushOracles
    /// @param balanceLedger The deployed BalanceLedger proxy (collateral source)
    /// @param centuari The deployed Centuari proxy (debt source; must be on the Phase 3 impl)
    /// @param proxyAdminOwner Owner of the new proxies' TransparentUpgradeableProxy admins
    /// @param rwaAssets Assets with no live market feed → each gets a PushOracle
    function run(
        address owner,
        address operator,
        address balanceLedger,
        address centuari,
        address proxyAdminOwner,
        address[] calldata rwaAssets
    )
        external
        returns (
            address oracleRouterProxy,
            address oracleRouterProxyAdmin,
            address riskModuleProxy,
            address riskModuleProxyAdmin
        )
    {
        vm.startBroadcast();

        // 1. OracleRouter (upgradeable, provider-agnostic).
        OracleRouter routerImpl = new OracleRouter();
        bytes memory routerInit = abi.encodeCall(OracleRouter.initialize, (owner));
        TransparentUpgradeableProxy routerProxy =
            new TransparentUpgradeableProxy(address(routerImpl), proxyAdminOwner, routerInit);
        oracleRouterProxy = address(routerProxy);
        oracleRouterProxyAdmin = _getProxyAdmin(oracleRouterProxy);

        // 2. A PushOracle per RWA/synthetic asset, registered as its IPriceFeed.
        for (uint256 i = 0; i < rwaAssets.length; ++i) {
            PushOracle push = new PushOracle(owner, operator);
            OracleRouter(oracleRouterProxy).setFeed(rwaAssets[i], address(push));
            console.log("PushOracle for asset:", rwaAssets[i], "->", address(push));
        }

        // 3. Real RiskModule (upgradeable), wired to oracle + centuari + ledger.
        RiskModule rmImpl = new RiskModule();
        bytes memory rmInit = abi.encodeCall(RiskModule.initialize, (owner, oracleRouterProxy, centuari, balanceLedger));
        TransparentUpgradeableProxy rmProxy = new TransparentUpgradeableProxy(address(rmImpl), proxyAdminOwner, rmInit);
        riskModuleProxy = address(rmProxy);
        riskModuleProxyAdmin = _getProxyAdmin(riskModuleProxy);

        vm.stopBroadcast();

        console.log("=== RiskModule Stack Deployment Complete (Phase 3 / C6) ===");
        console.log("OracleRouter Proxy:", oracleRouterProxy);
        console.log("OracleRouter ProxyAdmin:", oracleRouterProxyAdmin);
        console.log("RiskModule Proxy:", riskModuleProxy);
        console.log("RiskModule ProxyAdmin:", riskModuleProxyAdmin);
        console.log("Owner:", owner);
        console.log("Operator:", operator);
        console.log("FOLLOW-UP (governance): per-asset setLtv/setBuffer/setMaxStaleness +");
        console.log("  Chainlink ChainlinkPriceFeed setFeed; then push initial prices.");
        console.log("GATED (Phase 4, post-audit): setRiskModule on WithdrawalRegistry + CollateralManager.");
    }

    /// @notice Read the ProxyAdmin address from a TransparentUpgradeableProxy
    function _getProxyAdmin(address proxy) internal view returns (address) {
        bytes32 adminSlot = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
        bytes32 adminValue = vm.load(proxy, adminSlot);
        return address(uint160(uint256(adminValue)));
    }
}
