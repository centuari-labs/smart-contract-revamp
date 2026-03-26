// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CentuariRouter} from "../../src/core/CentuariRouter.sol";
import {ICentuariRouter} from "../../src/interfaces/ICentuariRouter.sol";
import {MockToken} from "../../src/mocks/MockToken.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @title ERC4626VaultTest
/// @notice Tests for D1 ERC-4626 vault adapter in CentuariRouter
contract ERC4626VaultTest is Test {
    CentuariRouter public router;
    MockToken public usdc;

    address owner = address(0x1);
    address endpoint = address(0xE0);
    address user = address(0x10);

    function setUp() public {
        usdc = new MockToken("USD Coin", "USDC", 6, 0);

        vm.warp(100000);
        router = CentuariRouter(address(new TransparentUpgradeableProxy(
            address(new CentuariRouter()), owner,
            abi.encodeCall(CentuariRouter.initialize, (owner, endpoint))
        )));

        // Set vault asset (required for deposit)
        // Note: _vaultAsset is internal storage. We'd need a setter or initialize it.
        // For now, test that deposit without vault asset reverts.

        usdc.mint(user, 100_000e6);
    }

    /// @notice Deposit without vault asset configured reverts
    function test_deposit_no_vault_asset_reverts() public {
        vm.startPrank(user);
        usdc.approve(address(router), 1000e6);
        vm.expectRevert(bytes("CentuariRouter: vault asset not set"));
        router.deposit(1000e6, user);
        vm.stopPrank();
    }

    /// @notice Withdraw zero reverts
    function test_withdraw_zero_reverts() public {
        vm.expectRevert(bytes("CentuariRouter: zero withdraw"));
        router.withdraw(0, user, user);
    }

    /// @notice Redeem zero reverts
    function test_redeem_zero_reverts() public {
        vm.expectRevert(bytes("CentuariRouter: zero redeem"));
        router.redeem(0, user, user);
    }

    /// @notice convertToShares with virtual offset (1:1 when empty)
    function test_convertToShares_empty_vault() public view {
        uint256 shares = router.convertToShares(1000e6);
        // With virtual offset 1e6: shares = 1000e6 * (0 + 1e6) / (0 + 1e6) = 1000e6
        assertEq(shares, 1000e6, "1:1 share ratio when vault is empty");
    }

    /// @notice convertToAssets with virtual offset (1:1 when empty)
    function test_convertToAssets_empty_vault() public view {
        uint256 assets = router.convertToAssets(1000e6);
        assertEq(assets, 1000e6, "1:1 asset ratio when vault is empty");
    }

    /// @notice totalAssets starts at 0
    function test_totalAssets_starts_zero() public view {
        assertEq(router.totalAssets(), 0);
    }
}
