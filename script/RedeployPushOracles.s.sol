// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

import {OracleRouter} from "../src/core/oracle/OracleRouter.sol";
import {PushOracle} from "../src/core/oracle/PushOracle.sol";

/// @title RedeployPushOracles
/// @notice Redeploys the per-asset `PushOracle` feeds carrying the SC-2 hardening
///         (owner-settable price bounds + max-deviation-per-update guard) and
///         re-points the EXISTING `OracleRouter` at them via `setFeed`.
/// @dev `PushOracle` is non-upgradeable, so shipping the SC-2 bytecode requires a
///      fresh deploy + `setFeed` swap. This script intentionally does NOT redeploy
///      the router and does NOT touch per-asset staleness windows — those live on
///      the router (`_maxStaleness[asset]`) and persist across feed swaps. New
///      oracles keep the generous constructor defaults (min = 1, max = unbounded,
///      deviation = 50%); the owner tightens bounds per asset later if desired.
///
///      Broadcast by the `OracleRouter` owner (`setFeed` is `onlyOwner`). Price
///      pushes are a separate step with the operator key (`setPrice` is
///      `onlyOperator`). After wiring, asserts every asset retains a non-zero
///      staleness window (SC-3) — aborts in simulation before broadcasting if not.
///
///      Invocation:
///        forge script script/RedeployPushOracles.s.sol:RedeployPushOracles \
///          --sig "run(address,address,address,address[])" \
///          $OWNER $OPERATOR $ORACLE_ROUTER "[$ASSET1,$ASSET2,...]" \
///          --rpc-url $RPC --private-key $PRIVATE_KEY --broadcast
contract RedeployPushOracles is Script {
    /// @param owner Governance owner of each new PushOracle (can set bounds / rotate operator).
    /// @param operator Price-pushing operator key for the new PushOracles.
    /// @param oracleRouter The already-deployed OracleRouter proxy to re-point.
    /// @param assets Assets to redeploy a PushOracle for (each re-`setFeed`-ed on the router).
    function run(address owner, address operator, address oracleRouter, address[] calldata assets) external {
        OracleRouter router = OracleRouter(oracleRouter);

        vm.startBroadcast();
        for (uint256 i = 0; i < assets.length; ++i) {
            PushOracle push = new PushOracle(owner, operator);
            router.setFeed(assets[i], address(push));
            console.log("NEWORACLE asset:", assets[i], "->", address(push));
        }
        vm.stopBroadcast();

        // SC-3: every priced asset must carry a non-zero staleness window. The
        // feed swap does not touch staleness, so this re-confirms the pre-existing
        // 86400s windows survived — and fail-fasts if any asset is unconfigured.
        for (uint256 i = 0; i < assets.length; ++i) {
            require(router.maxStalenessOf(assets[i]) != 0, "RedeployPushOracles: asset missing staleness window (SC-3)");
        }

        console.log("Redeployed PushOracles; router re-wired; staleness non-zero. count:", assets.length);
    }
}
