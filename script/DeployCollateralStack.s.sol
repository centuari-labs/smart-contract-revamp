// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {RiskModuleStub} from "../src/core/risk/RiskModuleStub.sol";
import {CollateralManager} from "../src/core/collateral/CollateralManager.sol";
import {BalanceLedger} from "../src/core/balance-ledger/BalanceLedger.sol";

/// @title DeployCollateralStack
/// @notice Deploys the Phase 1a collateral primitives (RiskModuleStub + CollateralManager)
///         on top of an already-deployed BalanceLedger and wires the writer
///         allowlist via the testnet `forceAddWriter` fast path.
/// @dev Assumes:
///      - BalanceLedger is already deployed behind its own proxy
///      - `forceWriterRegistrationEnabled` was set to true at BalanceLedger init
///        (testnet only — production path uses `proposeAuthorizedWriter` + 48h
///        timelock + `executeAuthorizedWriter`)
///      - The caller of this script holds `BalanceLedger.owner()` so
///        `forceAddWriter` succeeds
///
///      Output addresses should be merged into
///      `deployments/deploy-<network>-latest.json` by the caller.
contract DeployCollateralStack is Script {
    /// @param owner Governance owner of the new CollateralManager
    /// @param operator Protocol settlement key allowed to call flagFor/unflagFor
    /// @param balanceLedger The already-deployed BalanceLedger proxy address
    /// @param proxyAdminOwner Owner of the CollateralManager's TransparentUpgradeableProxy admin
    function run(address owner, address operator, address balanceLedger, address proxyAdminOwner)
        external
        returns (
            address riskModuleStub,
            address collateralManagerProxy,
            address collateralManagerImpl,
            address collateralManagerProxyAdmin
        )
    {
        vm.startBroadcast();

        // 1. Deploy the Phase 1 RiskModuleStub (stateless, unupgradable — will
        //    be replaced by the Phase 2 oracle-backed RiskModule via a single
        //    `CollateralManager.setRiskModule(newAddr)` governance call).
        RiskModuleStub stub = new RiskModuleStub(balanceLedger);
        riskModuleStub = address(stub);

        // 2. Deploy the CollateralManager implementation + proxy.
        CollateralManager mgrImpl = new CollateralManager();
        collateralManagerImpl = address(mgrImpl);

        bytes memory initData =
            abi.encodeCall(CollateralManager.initialize, (owner, operator, balanceLedger, riskModuleStub));

        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(collateralManagerImpl, proxyAdminOwner, initData);
        collateralManagerProxy = address(proxy);
        collateralManagerProxyAdmin = _getProxyAdmin(collateralManagerProxy);

        // 3. Authorize the CollateralManager as a BalanceLedger writer via the
        //    testnet fast path. On mainnet this becomes a two-step ceremony:
        //      BalanceLedger.proposeAuthorizedWriter(mgr)
        //      (wait 48h)
        //      BalanceLedger.executeAuthorizedWriter(mgr)
        BalanceLedger(balanceLedger).forceAddWriter(collateralManagerProxy);

        vm.stopBroadcast();

        console.log("=== Collateral Stack Deployment Complete ===");
        console.log("RiskModuleStub:", riskModuleStub);
        console.log("CollateralManager Impl:", collateralManagerImpl);
        console.log("CollateralManager Proxy:", collateralManagerProxy);
        console.log("CollateralManager ProxyAdmin:", collateralManagerProxyAdmin);
        console.log("BalanceLedger:", balanceLedger);
        console.log("Owner:", owner);
        console.log("Operator:", operator);
    }

    /// @notice Get the ProxyAdmin address from a TransparentUpgradeableProxy
    function _getProxyAdmin(address proxy) internal view returns (address) {
        bytes32 adminSlot = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
        bytes32 adminValue = vm.load(proxy, adminSlot);
        return address(uint160(uint256(adminValue)));
    }
}
