// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {BalanceLedger} from "../../src/core/BalanceLedger.sol";
import {IBalanceLedger} from "../../src/interfaces/IBalanceLedger.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @notice Minimal mock for RiskModule HF check in setAsCollateral
contract MockRiskModuleForCBT {
    uint256 public weightedCollateral = 10_000e18;
    uint256 public totalDebt = 0;

    function setValues(uint256 wc, uint256 td) external {
        weightedCollateral = wc;
        totalDebt = td;
    }

    function getWeightedCollateralExcluding(address, address) external view returns (uint256) {
        return weightedCollateral;
    }

    function getTotalDebtUSD(address) external view returns (uint256) {
        return totalDebt;
    }

    function getHealthFactor(address) external view returns (uint256) {
        if (totalDebt == 0) return type(uint256).max;
        return (weightedCollateral * 1e18) / totalDebt;
    }
}

/// @title FlowH_CBTCollateral
/// @notice Integration test: CBT used as collateral, contributing to weighted HF
contract FlowH_CBTCollateralTest is Test {
    BalanceLedger public ledger;
    MockRiskModuleForCBT public riskModule;

    address owner = address(0x1);
    address lender = address(0x10);
    address cbtAddress = address(0xCB7); // Mock CBT address

    function setUp() public {
        riskModule = new MockRiskModuleForCBT();

        ledger = BalanceLedger(address(new TransparentUpgradeableProxy(
            address(new BalanceLedger()), owner,
            abi.encodeCall(BalanceLedger.initialize, (owner))
        )));

        vm.warp(100000);
        vm.startPrank(owner);
        ledger.proposeAuthorizedWriter(address(this), true);
        vm.warp(100000 + 48 hours + 1);
        ledger.applyAuthorizedWriter();
        ledger.proposeAdminChange("riskModule", address(riskModule));
        vm.warp(100000 + 96 hours + 2);
        ledger.applyAdminChange("riskModule");
        vm.stopPrank();
    }

    /// @notice Add CBT as collateral -> enable -> verify isUsedAsCollateral
    function test_flowH_cbt_as_collateral() public {
        // Add CBT as collateral for lender
        ledger.addCollateral(lender, cbtAddress, 10_000e6, 42161);

        // Verify collateral added
        IBalanceLedger.CollateralPosition[] memory positions = ledger.getCollateral(lender);
        assertEq(positions.length, 1);
        assertEq(positions[0].asset, cbtAddress);
        assertEq(positions[0].amount, 10_000e6);

        // isUsedAsCollateral auto-enabled
        assertTrue(ledger.getIsUsedAsCollateral(lender, cbtAddress));
    }

    /// @notice Cannot disable CBT collateral if it would cause undercollateralization
    function test_flowH_disable_cbt_collateral_blocked_by_debt() public {
        ledger.addCollateral(lender, cbtAddress, 10_000e6, 42161);

        // Set RiskModule to show debt that depends on this collateral
        riskModule.setValues(0, 5_000e18); // weightedCollateral=0 without CBT, debt=5000

        vm.prank(lender);
        vm.expectRevert(IBalanceLedger.WouldCauseUndercollateralization.selector);
        ledger.setAsCollateral(cbtAddress, false);
    }

    /// @notice Can disable CBT collateral when no debt
    function test_flowH_disable_cbt_collateral_no_debt() public {
        ledger.addCollateral(lender, cbtAddress, 10_000e6, 42161);

        riskModule.setValues(0, 0); // No debt

        vm.prank(lender);
        ledger.setAsCollateral(cbtAddress, false);

        assertFalse(ledger.getIsUsedAsCollateral(lender, cbtAddress));
    }
}
