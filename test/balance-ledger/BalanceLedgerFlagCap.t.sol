// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {BalanceLedger} from "../../src/core/balance-ledger/BalanceLedger.sol";
import {IBalanceLedger} from "../../src/interfaces/IBalanceLedger.sol";

/// @title BalanceLedgerFlagCapTest
/// @notice SC-5: the per-user flagged-collateral set is capped (MAX_FLAGGED_ASSETS)
///         so the RiskModule's HF loop — one oracle call per flagged asset — can
///         never be pushed past the block gas limit by a user flagging unboundedly.
contract BalanceLedgerFlagCapTest is Test {
    BalanceLedger internal ledger;
    address internal owner = makeAddr("owner");
    address internal writer = address(this);
    address internal user = makeAddr("user");

    uint256 internal constant CAP = 32; // MAX_FLAGGED_ASSETS

    function setUp() public {
        BalanceLedger impl = new BalanceLedger();
        bytes memory initData = abi.encodeCall(BalanceLedger.initialize, (owner, true));
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(impl), makeAddr("admin"), initData);
        ledger = BalanceLedger(address(proxy));

        vm.prank(owner);
        ledger.forceAddWriter(writer);
    }

    function _asset(uint256 i) internal pure returns (address) {
        return address(uint160(0x1000 + i));
    }

    function _flagN(uint256 n) internal {
        for (uint256 i = 0; i < n; ++i) {
            ledger.markCollateral(user, _asset(i));
        }
    }

    function test_flagUpToCap_succeeds() public {
        _flagN(CAP);
        assertEq(ledger.flaggedAssetsOf(user).length, CAP);
    }

    function test_flagBeyondCap_reverts() public {
        _flagN(CAP);
        vm.expectRevert(IBalanceLedger.TooManyFlaggedAssets.selector);
        ledger.markCollateral(user, _asset(CAP)); // the (CAP+1)th distinct asset
    }

    function test_reflaggingExistingAsset_doesNotCountAgainstCap() public {
        _flagN(CAP);
        // Re-flagging an already-flagged asset is an idempotent no-op (must not revert).
        ledger.markCollateral(user, _asset(0));
        assertEq(ledger.flaggedAssetsOf(user).length, CAP);
    }

    function test_unflagFreesASlot() public {
        _flagN(CAP);
        ledger.unmarkCollateral(user, _asset(0)); // frees one slot
        ledger.markCollateral(user, _asset(CAP)); // now fits again
        assertEq(ledger.flaggedAssetsOf(user).length, CAP);
    }
}
