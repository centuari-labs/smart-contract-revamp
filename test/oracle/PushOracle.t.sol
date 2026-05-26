// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PushOracle} from "../../src/core/oracle/PushOracle.sol";

contract PushOracleTest is Test {
    PushOracle internal oracle;
    address internal owner = makeAddr("owner");
    address internal operator = makeAddr("operator");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        oracle = new PushOracle(owner, operator);
    }

    function test_initialState_isZero() public view {
        (uint256 p, uint256 u) = oracle.latestPriceUsd();
        assertEq(p, 0);
        assertEq(u, 0);
        assertEq(oracle.operator(), operator);
        assertEq(oracle.owner(), owner);
    }

    function test_setPrice_stampsTimestamp() public {
        vm.warp(1000);
        vm.prank(operator);
        oracle.setPrice(2_000e18);
        (uint256 p, uint256 u) = oracle.latestPriceUsd();
        assertEq(p, 2_000e18);
        assertEq(u, 1000);
    }

    function test_setPrice_onlyOperator() public {
        vm.prank(stranger);
        vm.expectRevert(PushOracle.NotOperator.selector);
        oracle.setPrice(1e18);
    }

    function test_setOperator_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        oracle.setOperator(makeAddr("newOp"));
    }

    function test_setOperator_rotates() public {
        address newOp = makeAddr("newOp");
        vm.prank(owner);
        oracle.setOperator(newOp);
        assertEq(oracle.operator(), newOp);

        vm.prank(newOp);
        oracle.setPrice(5e18);
        (uint256 p,) = oracle.latestPriceUsd();
        assertEq(p, 5e18);

        // old operator can no longer push
        vm.prank(operator);
        vm.expectRevert(PushOracle.NotOperator.selector);
        oracle.setPrice(9e18);
    }

    function test_setOperator_zeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(PushOracle.ZeroAddress.selector);
        oracle.setOperator(address(0));
    }

    function test_constructor_zeroOperatorReverts() public {
        vm.expectRevert(PushOracle.ZeroAddress.selector);
        new PushOracle(owner, address(0));
    }

    // ============ SC-2: defaults ============

    function test_defaults_generousBoundsAndDeviation() public view {
        (uint256 minP, uint256 maxP) = oracle.priceBounds();
        assertEq(minP, 1);
        assertEq(maxP, type(uint256).max);
        assertEq(oracle.maxDeviationBps(), 5000); // 50%
    }

    function test_setPrice_zeroReverts_belowMin() public {
        vm.prank(operator);
        vm.expectRevert(PushOracle.PriceOutOfBounds.selector);
        oracle.setPrice(0); // below default min of 1
    }

    // ============ SC-2: absolute bounds ============

    function test_setPrice_belowMin_reverts() public {
        vm.prank(owner);
        oracle.setBounds(1e18, 100e18);
        vm.prank(operator);
        vm.expectRevert(PushOracle.PriceOutOfBounds.selector);
        oracle.setPrice(0.5e18);
    }

    function test_setPrice_aboveMax_reverts() public {
        vm.prank(owner);
        oracle.setBounds(1e18, 100e18);
        vm.prank(operator);
        vm.expectRevert(PushOracle.PriceOutOfBounds.selector);
        oracle.setPrice(101e18);
    }

    function test_setPrice_withinBounds_ok() public {
        vm.prank(owner);
        oracle.setBounds(1e18, 100e18);
        vm.prank(operator);
        oracle.setPrice(50e18);
        (uint256 p,) = oracle.latestPriceUsd();
        assertEq(p, 50e18);
    }

    // ============ SC-2: deviation guard ============

    function test_firstPush_exemptFromDeviation() public {
        // Default deviation is 50%, but the first push has no prior price to
        // compare against — any in-bounds value is accepted.
        vm.prank(operator);
        oracle.setPrice(1_000_000e18);
        (uint256 p,) = oracle.latestPriceUsd();
        assertEq(p, 1_000_000e18);
    }

    function test_secondPush_withinDeviation_ok() public {
        vm.startPrank(operator);
        oracle.setPrice(100e18);
        oracle.setPrice(120e18); // +20% ≤ 50%
        vm.stopPrank();
        (uint256 p,) = oracle.latestPriceUsd();
        assertEq(p, 120e18);
    }

    function test_secondPush_aboveDeviation_reverts() public {
        vm.startPrank(operator);
        oracle.setPrice(100e18);
        vm.expectRevert(PushOracle.PriceDeviationTooLarge.selector);
        oracle.setPrice(200e18); // +100% > 50%
        vm.stopPrank();
    }

    function test_secondPush_belowDeviation_reverts() public {
        vm.startPrank(operator);
        oracle.setPrice(100e18);
        vm.expectRevert(PushOracle.PriceDeviationTooLarge.selector);
        oracle.setPrice(40e18); // -60% > 50%
        vm.stopPrank();
    }

    // ============ SC-2: owner-only setters ============

    function test_setBounds_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        oracle.setBounds(1e18, 100e18);
    }

    function test_setBounds_invalidReverts() public {
        vm.startPrank(owner);
        vm.expectRevert(PushOracle.InvalidBounds.selector);
        oracle.setBounds(0, 100e18); // min == 0
        vm.expectRevert(PushOracle.InvalidBounds.selector);
        oracle.setBounds(100e18, 100e18); // min >= max
        vm.stopPrank();
    }

    function test_setMaxDeviation_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        oracle.setMaxDeviationBps(1000);
    }

    function test_setMaxDeviation_zeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(PushOracle.InvalidDeviation.selector);
        oracle.setMaxDeviationBps(0);
    }

    function test_setMaxDeviation_tighten_thenEnforced() public {
        vm.prank(owner);
        oracle.setMaxDeviationBps(1000); // 10%
        vm.startPrank(operator);
        oracle.setPrice(100e18);
        vm.expectRevert(PushOracle.PriceDeviationTooLarge.selector);
        oracle.setPrice(120e18); // +20% > 10%
        vm.stopPrank();
    }
}
