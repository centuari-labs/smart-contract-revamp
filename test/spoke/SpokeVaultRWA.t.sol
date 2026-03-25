// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SpokeVaultRWA} from "../../src/spoke/SpokeVaultRWA.sol";
import {ISpokeVaultRWA} from "../../src/interfaces/ISpokeVaultRWA.sol";
import {MockToken} from "../../src/mocks/MockToken.sol";

contract SpokeVaultRWATest is Test {
    SpokeVaultRWA public vault;
    MockToken public token;

    address public owner = address(0x1);
    address public user = address(0x10);
    address public liquidator = address(0x20);
    address public layerZeroEndpoint = address(0x30);
    address public hubLiqEngine = address(0x40);

    uint32 constant HUB_EID = 42161;
    uint256 constant DEPOSIT_AMOUNT = 1_000e18;

    function setUp() public {
        token = new MockToken("Ondo OUSG", "OUSG", 18, 0);

        vm.prank(owner);
        vault = new SpokeVaultRWA(owner);

        vm.startPrank(owner);
        vault.setLayerZeroEndpoint(layerZeroEndpoint);
        vault.setHubLiquidationEngine(hubLiqEngine);
        vault.setHubChainEid(HUB_EID);
        vm.stopPrank();

        token.mint(user, 100_000e18);
        vm.prank(user);
        token.approve(address(vault), type(uint256).max);
    }

    // ============ test_deposit_locks_tokens ============

    function test_deposit_locks_tokens() public {
        uint256 userBefore = token.balanceOf(user);
        uint256 vaultBefore = token.balanceOf(address(vault));

        vm.expectEmit(true, true, false, true);
        emit ISpokeVaultRWA.RWADeposited(user, address(token), DEPOSIT_AMOUNT);

        vm.prank(user);
        vault.deposit(address(token), DEPOSIT_AMOUNT);

        assertEq(token.balanceOf(user), userBefore - DEPOSIT_AMOUNT);
        assertEq(token.balanceOf(address(vault)), vaultBefore + DEPOSIT_AMOUNT);
        assertEq(vault.lockedBalances(user, address(token)), DEPOSIT_AMOUNT);
    }

    // ============ test_deposit_frozen_asset_reverts ============

    function test_deposit_frozen_asset_reverts() public {
        vm.prank(owner);
        vault.reportFrozen(address(token));

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ISpokeVaultRWA.AssetFrozen.selector, address(token)));
        vault.deposit(address(token), DEPOSIT_AMOUNT);
    }

    // ============ test_deposit_zero_amount_reverts ============

    function test_deposit_zero_amount_reverts() public {
        vm.prank(user);
        vm.expectRevert(ISpokeVaultRWA.ZeroAmount.selector);
        vault.deposit(address(token), 0);
    }

    // ============ test_lzReceive_valid_releases_tokens ============

    function test_lzReceive_valid_releases_tokens() public {
        // First deposit tokens into vault
        vm.prank(user);
        vault.deposit(address(token), DEPOSIT_AMOUNT);

        uint256 liquidatorBefore = token.balanceOf(liquidator);
        uint256 vaultBefore = token.balanceOf(address(vault));

        vm.expectEmit(true, true, false, true);
        emit ISpokeVaultRWA.LiquidationReleased(user, address(token), DEPOSIT_AMOUNT, liquidator);

        bytes memory message = abi.encode(user, address(token), DEPOSIT_AMOUNT, liquidator);
        vm.prank(layerZeroEndpoint);
        vault.lzReceive(HUB_EID, bytes32(uint256(uint160(hubLiqEngine))), message);

        assertEq(token.balanceOf(liquidator), liquidatorBefore + DEPOSIT_AMOUNT);
        assertEq(token.balanceOf(address(vault)), vaultBefore - DEPOSIT_AMOUNT);
        assertEq(vault.lockedBalances(user, address(token)), 0);
    }

    // ============ test_lzReceive_wrong_endpoint_reverts ============

    function test_lzReceive_wrong_endpoint_reverts() public {
        bytes memory message = abi.encode(user, address(token), DEPOSIT_AMOUNT, liquidator);

        vm.prank(address(0xDEAD)); // not the LayerZero endpoint
        vm.expectRevert("SpokeVaultRWA: only LZ");
        vault.lzReceive(HUB_EID, bytes32(uint256(uint160(hubLiqEngine))), message);
    }

    // ============ test_lzReceive_wrong_chain_reverts ============

    function test_lzReceive_wrong_chain_reverts() public {
        bytes memory message = abi.encode(user, address(token), DEPOSIT_AMOUNT, liquidator);

        vm.prank(layerZeroEndpoint);
        vm.expectRevert("SpokeVaultRWA: invalid source chain");
        vault.lzReceive(
            uint32(9999), // wrong chain EID
            bytes32(uint256(uint160(hubLiqEngine))),
            message
        );
    }

    // ============ test_lzReceive_wrong_sender_reverts ============

    function test_lzReceive_wrong_sender_reverts() public {
        bytes memory message = abi.encode(user, address(token), DEPOSIT_AMOUNT, liquidator);

        vm.prank(layerZeroEndpoint);
        vm.expectRevert("SpokeVaultRWA: invalid hub sender");
        vault.lzReceive(
            HUB_EID,
            bytes32(uint256(uint160(address(0xBAD)))), // wrong sender
            message
        );
    }

    // ============ test_reportFrozen_only_owner ============

    function test_reportFrozen_only_owner() public {
        // Non-owner cannot freeze
        vm.prank(user);
        vm.expectRevert();
        vault.reportFrozen(address(token));

        // Owner can freeze
        vm.expectEmit(true, false, false, false);
        emit ISpokeVaultRWA.AssetFrozenReported(address(token));

        vm.prank(owner);
        vault.reportFrozen(address(token));

        assertTrue(vault.frozenAssets(address(token)));
    }
}
