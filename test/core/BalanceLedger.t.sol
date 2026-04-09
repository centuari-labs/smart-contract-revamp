// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {BalanceLedger} from "../../src/core/BalanceLedger.sol";
import {IBalanceLedger} from "../../src/interfaces/IBalanceLedger.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @notice Mock RiskModule for setAsCollateral safety tests
contract MockRiskModule {
    uint256 public mockWeightedCollateral;
    uint256 public mockTotalDebt;

    function setMockValues(uint256 weightedColl, uint256 totalDebt) external {
        mockWeightedCollateral = weightedColl;
        mockTotalDebt = totalDebt;
    }

    function getWeightedCollateralExcluding(address, address) external view returns (uint256) {
        return mockWeightedCollateral;
    }

    function getTotalDebtUSD(address) external view returns (uint256) {
        return mockTotalDebt;
    }
}

contract BalanceLedgerTest is Test {
    BalanceLedger public ledger;
    MockRiskModule public riskModule;

    address public owner = address(0x1);
    address public authorizedWriter = address(0x2);
    address public user1 = address(0x10);
    address public user2 = address(0x20);
    address public usdc = address(0x100);
    address public ousg = address(0x200);
    address public proxyAdmin;

    function setUp() public {
        // Deploy implementation
        BalanceLedger impl = new BalanceLedger();

        // Deploy proxy
        bytes memory initData = abi.encodeCall(BalanceLedger.initialize, (owner));
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(impl), owner, initData
        );
        ledger = BalanceLedger(address(proxy));

        // Get proxy admin from ERC1967 slot
        bytes32 adminSlot = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
        proxyAdmin = address(uint160(uint256(vm.load(address(proxy), adminSlot))));

        // Deploy mock risk module
        riskModule = new MockRiskModule();

        // Configure authorized writer
        vm.warp(1000);
        vm.startPrank(owner);
        ledger.proposeAuthorizedWriter(authorizedWriter, true);
        vm.warp(1000 + 48 hours + 1);
        ledger.applyAuthorizedWriter();
        ledger.proposeAdminChange("riskModule", address(riskModule));
        vm.warp(1000 + 96 hours + 2);
        ledger.applyAdminChange("riskModule");
        vm.stopPrank();
    }

    // ============ Credit / Debit Tests ============

    function test_credit_success() public {
        vm.prank(authorizedWriter);
        ledger.credit(user1, usdc, 1000e6);

        assertEq(ledger.getAvailable(user1, usdc), 1000e6);
    }

    function test_credit_reverts_unauthorized() public {
        vm.prank(user1); // not authorized
        vm.expectRevert(IBalanceLedger.Unauthorized.selector);
        ledger.credit(user1, usdc, 1000e6);
    }

    function test_credit_reverts_zero_address() public {
        vm.prank(authorizedWriter);
        vm.expectRevert(IBalanceLedger.ZeroAddress.selector);
        ledger.credit(address(0), usdc, 1000e6);
    }

    function test_credit_reverts_zero_amount() public {
        vm.prank(authorizedWriter);
        vm.expectRevert(IBalanceLedger.ZeroAmount.selector);
        ledger.credit(user1, usdc, 0);
    }

    function test_debit_success() public {
        vm.prank(authorizedWriter);
        ledger.credit(user1, usdc, 1000e6);

        vm.prank(authorizedWriter);
        ledger.debit(user1, usdc, 400e6);

        assertEq(ledger.getAvailable(user1, usdc), 600e6);
    }

    function test_debit_reverts_insufficient() public {
        vm.prank(authorizedWriter);
        ledger.credit(user1, usdc, 100e6);

        vm.prank(authorizedWriter);
        vm.expectRevert(IBalanceLedger.InsufficientAvailable.selector);
        ledger.debit(user1, usdc, 200e6);
    }

    // ============ Lock / Unlock Tests (TOCTOU Fix) ============

    function test_lockForOrder_success() public {
        vm.prank(authorizedWriter);
        ledger.credit(user1, usdc, 1000e6);

        vm.prank(authorizedWriter);
        ledger.lockForOrder(user1, usdc, 600e6);

        assertEq(ledger.getAvailable(user1, usdc), 400e6);
        assertEq(ledger.getLocked(user1, usdc), 600e6);
    }

    function test_lockForOrder_reverts_insufficient_available() public {
        vm.prank(authorizedWriter);
        ledger.credit(user1, usdc, 100e6);

        vm.prank(authorizedWriter);
        vm.expectRevert(IBalanceLedger.InsufficientAvailable.selector);
        ledger.lockForOrder(user1, usdc, 200e6);
    }

    function test_unlockFromOrder_success() public {
        vm.prank(authorizedWriter);
        ledger.credit(user1, usdc, 1000e6);

        vm.prank(authorizedWriter);
        ledger.lockForOrder(user1, usdc, 600e6);

        vm.prank(authorizedWriter);
        ledger.unlockFromOrder(user1, usdc, 400e6);

        assertEq(ledger.getAvailable(user1, usdc), 800e6);
        assertEq(ledger.getLocked(user1, usdc), 200e6);
    }

    function test_unlockFromOrder_reverts_insufficient_locked() public {
        vm.prank(authorizedWriter);
        ledger.credit(user1, usdc, 1000e6);

        vm.prank(authorizedWriter);
        ledger.lockForOrder(user1, usdc, 100e6);

        vm.prank(authorizedWriter);
        vm.expectRevert(IBalanceLedger.InsufficientLocked.selector);
        ledger.unlockFromOrder(user1, usdc, 200e6);
    }

    function test_lock_unlock_roundtrip() public {
        vm.prank(authorizedWriter);
        ledger.credit(user1, usdc, 1000e6);

        vm.prank(authorizedWriter);
        ledger.lockForOrder(user1, usdc, 1000e6);

        assertEq(ledger.getAvailable(user1, usdc), 0);
        assertEq(ledger.getLocked(user1, usdc), 1000e6);

        vm.prank(authorizedWriter);
        ledger.unlockFromOrder(user1, usdc, 1000e6);

        assertEq(ledger.getAvailable(user1, usdc), 1000e6);
        assertEq(ledger.getLocked(user1, usdc), 0);
    }

    // ============ YieldRouter Tests ============

    function test_moveToYieldRouter_success() public {
        vm.prank(authorizedWriter);
        ledger.credit(user1, usdc, 1000e6);

        vm.prank(authorizedWriter);
        ledger.moveToYieldRouter(user1, usdc, 850e6, 840e6);

        IBalanceLedger.UserBalance memory bal = ledger.getBalance(user1, usdc);
        assertEq(bal.available, 150e6);
        assertEq(bal.inYieldRouter, 850e6);
        assertEq(bal.yieldRouterShares, 840e6);
    }

    function test_moveFromYieldRouter_success() public {
        vm.prank(authorizedWriter);
        ledger.credit(user1, usdc, 1000e6);

        vm.prank(authorizedWriter);
        ledger.moveToYieldRouter(user1, usdc, 850e6, 840e6);

        // Recall — amount matches what was deposited
        vm.prank(authorizedWriter);
        ledger.moveFromYieldRouter(user1, usdc, 850e6, 840e6);

        IBalanceLedger.UserBalance memory bal = ledger.getBalance(user1, usdc);
        assertEq(bal.available, 150e6 + 850e6); // original buffer + recalled
        assertEq(bal.inYieldRouter, 0);
        assertEq(bal.yieldRouterShares, 0);
    }

    // ============ Collateral Tests ============

    function test_addCollateral_success() public {
        vm.prank(authorizedWriter);
        ledger.addCollateral(user1, ousg, 100e18, block.chainid); // Ethereum chain ID = 1

        IBalanceLedger.CollateralPosition[] memory positions = ledger.getCollateral(user1);
        assertEq(positions.length, 1);
        assertEq(positions[0].asset, ousg);
        assertEq(positions[0].amount, 100e18);
        assertEq(positions[0].sourceChainId, 1);
        assertTrue(positions[0].state == IBalanceLedger.CollateralState.ACTIVE);

        // Should auto-enable as collateral
        assertTrue(ledger.getIsUsedAsCollateral(user1, ousg));
    }

    function test_addCollateral_accumulates() public {
        vm.prank(authorizedWriter);
        ledger.addCollateral(user1, ousg, 100e18, block.chainid);

        vm.prank(authorizedWriter);
        ledger.addCollateral(user1, ousg, 50e18, block.chainid);

        IBalanceLedger.CollateralPosition[] memory positions = ledger.getCollateral(user1);
        assertEq(positions.length, 1); // same slot
        assertEq(positions[0].amount, 150e18);
    }

    function test_freezeCollateral_success() public {
        vm.prank(authorizedWriter);
        ledger.addCollateral(user1, ousg, 100e18, block.chainid);

        vm.prank(authorizedWriter);
        ledger.freezeCollateral(user1, 0);

        IBalanceLedger.CollateralPosition[] memory positions = ledger.getCollateral(user1);
        assertTrue(positions[0].state == IBalanceLedger.CollateralState.FROZEN);
    }

    function test_freezeCollateral_reverts_not_active() public {
        vm.prank(authorizedWriter);
        ledger.addCollateral(user1, ousg, 100e18, block.chainid);

        vm.prank(authorizedWriter);
        ledger.freezeCollateral(user1, 0);

        // Trying to freeze again should revert
        vm.prank(authorizedWriter);
        vm.expectRevert(IBalanceLedger.CollateralNotActive.selector);
        ledger.freezeCollateral(user1, 0);
    }

    function test_reduceCollateral_success() public {
        vm.prank(authorizedWriter);
        ledger.addCollateral(user1, ousg, 100e18, block.chainid);

        vm.prank(authorizedWriter);
        ledger.reduceCollateral(user1, ousg, 30e18);

        IBalanceLedger.CollateralPosition[] memory positions = ledger.getCollateral(user1);
        assertEq(positions[0].amount, 70e18);
    }

    function test_reduceCollateral_reverts_insufficient() public {
        vm.prank(authorizedWriter);
        ledger.addCollateral(user1, ousg, 100e18, block.chainid);

        vm.prank(authorizedWriter);
        vm.expectRevert(IBalanceLedger.InsufficientCollateral.selector);
        ledger.reduceCollateral(user1, ousg, 150e18);
    }

    // ============ setAsCollateral Tests (Security Invariant #13) ============

    function test_setAsCollateral_enable() public {
        vm.prank(authorizedWriter);
        ledger.addCollateral(user1, ousg, 100e18, block.chainid);

        // Disable first
        vm.prank(user1);
        riskModule.setMockValues(0, 0); // no debt
        ledger.setAsCollateral(ousg, false);
        assertFalse(ledger.getIsUsedAsCollateral(user1, ousg));

        // Re-enable
        vm.prank(user1);
        ledger.setAsCollateral(ousg, true);
        assertTrue(ledger.getIsUsedAsCollateral(user1, ousg));
    }

    function test_setAsCollateral_reverts_would_undercollateralize() public {
        vm.prank(authorizedWriter);
        ledger.addCollateral(user1, ousg, 100e18, block.chainid);

        // Mock: removing this collateral would leave 0 weighted, but debt is 5000
        riskModule.setMockValues(0, 5000e18);

        vm.prank(user1);
        vm.expectRevert(IBalanceLedger.WouldCauseUndercollateralization.selector);
        ledger.setAsCollateral(ousg, false);
    }

    function test_setAsCollateral_allows_disable_when_no_debt() public {
        vm.prank(authorizedWriter);
        ledger.addCollateral(user1, ousg, 100e18, block.chainid);

        // Mock: no debt, so safe to disable
        riskModule.setMockValues(0, 0);

        vm.prank(user1);
        ledger.setAsCollateral(ousg, false);
        assertFalse(ledger.getIsUsedAsCollateral(user1, ousg));
    }

    // ============ Access Control Tests (Security Invariant #9) ============

    function test_authorized_writer_management() public {
        address newWriter = address(0x999);

        // Initially not authorized
        assertFalse(ledger.isAuthorizedWriter(newWriter));

        // Owner can add
        vm.warp(2000);
        vm.startPrank(owner);
        ledger.proposeAuthorizedWriter(newWriter, true);
        vm.warp(2000 + 48 hours + 1);
        ledger.applyAuthorizedWriter();
        assertTrue(ledger.isAuthorizedWriter(newWriter));

        // Owner can remove
        ledger.proposeAuthorizedWriter(newWriter, false);
        vm.warp(2000 + 96 hours + 2);
        ledger.applyAuthorizedWriter();
        vm.stopPrank();
        assertFalse(ledger.isAuthorizedWriter(newWriter));
    }

    function test_setAuthorizedWriter_reverts_non_owner() public {
        vm.prank(user1);
        vm.expectRevert(); // OwnableUnauthorizedAccount
        ledger.proposeAuthorizedWriter(user1, true);
    }

    function test_all_write_functions_revert_unauthorized() public {
        vm.startPrank(user1); // not authorized

        vm.expectRevert(IBalanceLedger.Unauthorized.selector);
        ledger.credit(user1, usdc, 100);

        vm.expectRevert(IBalanceLedger.Unauthorized.selector);
        ledger.debit(user1, usdc, 100);

        vm.expectRevert(IBalanceLedger.Unauthorized.selector);
        ledger.lockForOrder(user1, usdc, 100);

        vm.expectRevert(IBalanceLedger.Unauthorized.selector);
        ledger.unlockFromOrder(user1, usdc, 100);

        vm.expectRevert(IBalanceLedger.Unauthorized.selector);
        ledger.moveToYieldRouter(user1, usdc, 100, 100);

        vm.expectRevert(IBalanceLedger.Unauthorized.selector);
        ledger.moveFromYieldRouter(user1, usdc, 100, 100);

        vm.expectRevert(IBalanceLedger.Unauthorized.selector);
        ledger.addCollateral(user1, ousg, 100, block.chainid);

        vm.expectRevert(IBalanceLedger.Unauthorized.selector);
        ledger.freezeCollateral(user1, 0);

        vm.expectRevert(IBalanceLedger.Unauthorized.selector);
        ledger.reduceCollateral(user1, ousg, 100);

        vm.stopPrank();
    }

    // ============ Multi-Asset Tests ============

    function test_multiple_assets_independent() public {
        vm.startPrank(authorizedWriter);
        ledger.credit(user1, usdc, 1000e6);
        ledger.credit(user1, ousg, 500e18);
        vm.stopPrank();

        assertEq(ledger.getAvailable(user1, usdc), 1000e6);
        assertEq(ledger.getAvailable(user1, ousg), 500e18);

        vm.prank(authorizedWriter);
        ledger.debit(user1, usdc, 300e6);

        assertEq(ledger.getAvailable(user1, usdc), 700e6);
        assertEq(ledger.getAvailable(user1, ousg), 500e18); // unchanged
    }

    // ============ Proxy Upgrade Test ============

    function test_proxy_preserves_storage() public {
        // Credit some balance
        vm.prank(authorizedWriter);
        ledger.credit(user1, usdc, 1000e6);

        // Deploy new implementation
        BalanceLedger newImpl = new BalanceLedger();

        // Upgrade via proxy admin
        vm.prank(proxyAdmin);
        // The ProxyAdmin is the actual admin, call upgrade through it
        // For TransparentUpgradeableProxy, the admin calls upgradeToAndCall
        (bool success,) = proxyAdmin.call(
            abi.encodeWithSignature(
                "upgradeAndCall(address,address,bytes)",
                address(ledger),
                address(newImpl),
                ""
            )
        );
        assertTrue(success);

        // Verify state preserved
        assertEq(ledger.getAvailable(user1, usdc), 1000e6);
        assertTrue(ledger.isAuthorizedWriter(authorizedWriter));
    }

    // ============ Pause Tests ============

    function test_pause_blocks_operations() public {
        vm.prank(owner);
        ledger.pause();

        vm.prank(authorizedWriter);
        vm.expectRevert("BalanceLedger: paused");
        ledger.credit(user1, usdc, 1000e6);
    }

    function test_unpause_resumes_operations() public {
        vm.prank(owner);
        ledger.pause();

        vm.prank(owner);
        ledger.unpause();

        vm.prank(authorizedWriter);
        ledger.credit(user1, usdc, 1000e6);
        assertEq(ledger.getAvailable(user1, usdc), 1000e6);
    }

    // ============ getCollateralByAsset Tests ============

    function test_getCollateralByAsset_success() public {
        vm.prank(authorizedWriter);
        ledger.addCollateral(user1, ousg, 100e18, block.chainid);

        IBalanceLedger.CollateralPosition memory pos = ledger.getCollateralByAsset(user1, ousg);
        assertEq(pos.asset, ousg);
        assertEq(pos.amount, 100e18);
    }

    function test_getCollateralByAsset_reverts_not_found() public {
        vm.expectRevert(IBalanceLedger.CollateralNotFound.selector);
        ledger.getCollateralByAsset(user1, ousg);
    }
}
