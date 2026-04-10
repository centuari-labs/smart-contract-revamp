// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {BalanceLedger} from "../../src/core/balance-ledger/BalanceLedger.sol";
import {RiskModuleStub} from "../../src/core/risk/RiskModuleStub.sol";
import {IRiskModule} from "../../src/interfaces/IRiskModule.sol";

/// @title RiskModuleStubTest
/// @notice Verifies the conservative Phase 1 RiskModule policy:
///         - canUnflag always returns false (fail-closed);
///         - canWithdraw mirrors `!usedAsCollateral` regardless of amount.
contract RiskModuleStubTest is Test {
    BalanceLedger internal ledger;
    RiskModuleStub internal stub;

    address internal owner = address(0xA11CE);
    address internal writer = address(0xBEEF);
    address internal user = address(0x1111);
    address internal asset = address(0xA55E71);

    function setUp() public {
        BalanceLedger impl = new BalanceLedger();
        bytes memory initData = abi.encodeCall(BalanceLedger.initialize, (owner, true));
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(impl),
            address(this),
            initData
        );
        ledger = BalanceLedger(address(proxy));

        vm.prank(owner);
        ledger.forceAddWriter(writer);

        stub = new RiskModuleStub(address(ledger));
    }

    function test_Constructor_RevertZeroAddress() public {
        vm.expectRevert(RiskModuleStub.ZeroAddress.selector);
        new RiskModuleStub(address(0));
    }

    function test_CanUnflag_AlwaysFalse() public view {
        // Fail-closed regardless of flag state — the only Phase 1 path to
        // clear a flag is the auto-unflag loop in `Centuari.repay`.
        assertFalse(stub.canUnflag(user, asset));
    }

    function test_CanUnflag_AlwaysFalse_EvenWhenFlagged() public {
        vm.prank(writer);
        ledger.markCollateral(user, asset);
        assertFalse(stub.canUnflag(user, asset));
    }

    function test_CanWithdraw_TrueWhenNotFlagged() public view {
        assertTrue(stub.canWithdraw(user, asset, 1));
        assertTrue(stub.canWithdraw(user, asset, type(uint256).max));
    }

    function test_CanWithdraw_FalseWhenFlagged() public {
        vm.prank(writer);
        ledger.markCollateral(user, asset);
        assertFalse(stub.canWithdraw(user, asset, 1));
    }

    function test_CanWithdraw_IgnoresAmount() public {
        // Stub deliberately ignores amount — Phase 2 real RiskModule will use it.
        vm.prank(writer);
        ledger.markCollateral(user, asset);
        assertFalse(stub.canWithdraw(user, asset, 0));
        assertFalse(stub.canWithdraw(user, asset, type(uint256).max));
    }

    function test_ImplementsInterface() public view {
        // Sanity: the stub satisfies the seam that callers type against.
        IRiskModule iface = IRiskModule(address(stub));
        assertFalse(iface.canUnflag(user, asset));
        assertTrue(iface.canWithdraw(user, asset, 1));
    }
}
