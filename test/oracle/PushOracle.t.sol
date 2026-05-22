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
}
