// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {CollateralManager} from "../../src/core/collateral/CollateralManager.sol";
import {ReentrancyGuardUpgradeable} from "../../src/utils/ReentrancyGuardUpgradeable.sol";

/// @notice Permissive RiskModule: canUnflag/canWithdraw always true (view).
contract PermissiveRiskModule {
    function canUnflag(address, address) external pure returns (bool) {
        return true;
    }

    function canWithdraw(address, address, uint256) external pure returns (bool) {
        return true;
    }
}

/// @notice Malicious BalanceLedger that re-enters CollateralManager during a
///         flag/unflag write. CollateralManager stores `_balanceLedger` as an
///         address and casts to IBalanceLedger at the call sites, so this mock
///         only needs the three functions CollateralManager actually calls.
contract ReentrantLedger {
    CollateralManager public cm;
    bool public attackFlag;
    bool public attackUnflag;
    mapping(address => mapping(address => uint64)) internal _flaggedAt;

    function setCm(address cm_) external {
        cm = CollateralManager(cm_);
    }

    function arm(bool f, bool u) external {
        attackFlag = f;
        attackUnflag = u;
    }

    function setFlaggedAt(address u, address a, uint64 t) external {
        _flaggedAt[u][a] = t;
    }

    function flaggedAt(address u, address a) external view returns (uint64) {
        return _flaggedAt[u][a];
    }

    function markCollateral(address, address asset) external {
        if (attackFlag) {
            attackFlag = false;
            cm.flag(asset); // re-enter — must be blocked by nonReentrant
        }
    }

    function unmarkCollateral(address, address asset) external {
        if (attackUnflag) {
            attackUnflag = false;
            cm.unflag(asset); // re-enter — must be blocked by nonReentrant
        }
    }
}

/// @title CollateralManagerReentrancyTest
/// @notice SC-10: flag/unflag are nonReentrant. A hostile/buggy BalanceLedger that
///         tries to re-enter during markCollateral/unmarkCollateral is rejected.
contract CollateralManagerReentrancyTest is Test {
    CollateralManager internal cm;
    ReentrantLedger internal ledger;
    PermissiveRiskModule internal rm;

    address internal owner = makeAddr("owner");
    address internal operator = makeAddr("operator");
    address internal user = makeAddr("user");
    address internal asset = makeAddr("asset");

    function setUp() public {
        vm.warp(1000);
        ledger = new ReentrantLedger();
        rm = new PermissiveRiskModule();
        CollateralManager impl = new CollateralManager();
        bytes memory initData =
            abi.encodeCall(CollateralManager.initialize, (owner, operator, address(ledger), address(rm)));
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(impl), makeAddr("admin"), initData);
        cm = CollateralManager(address(proxy));
        ledger.setCm(address(cm));

        vm.prank(owner);
        cm.setFlagLock(0); // skip the 24h lock for the unflag path
    }

    function test_flag_reentrancyBlocked() public {
        ledger.arm(true, false);
        vm.prank(operator);
        vm.expectRevert(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector);
        cm.flagFor(user, asset);
    }

    function test_unflag_reentrancyBlocked() public {
        ledger.setFlaggedAt(user, asset, 1); // make the flag "exist" so _unflag proceeds
        ledger.arm(false, true);
        vm.prank(operator);
        vm.expectRevert(ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector);
        cm.unflagFor(user, asset);
    }

    function test_normalFlag_succeeds() public {
        // Not armed → no re-entry → flag completes without reverting.
        ledger.arm(false, false);
        vm.prank(operator);
        cm.flagFor(user, asset);
    }
}
