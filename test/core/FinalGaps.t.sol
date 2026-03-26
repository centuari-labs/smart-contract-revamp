// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CentuariRouter} from "../../src/core/CentuariRouter.sol";
import {ICentuariRouter} from "../../src/interfaces/ICentuariRouter.sol";
import {YieldRouter} from "../../src/core/YieldRouter.sol";
import {ProtocolTreasury} from "../../src/core/ProtocolTreasury.sol";
import {BalanceLedger} from "../../src/core/BalanceLedger.sol";
import {MockToken} from "../../src/mocks/MockToken.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @dev Minimal mock adapter for YieldRouter tests
contract MockAdapter {
    mapping(address => uint256) public deployed;
    function deploy(address asset, uint256 amount) external returns (uint256) {
        deployed[asset] += amount;
        return amount; // 1:1 shares
    }
    function recall(address asset, uint256 shares) external returns (uint256) {
        deployed[asset] -= shares;
        return shares;
    }
    function getDeployedValue(address, uint256 shares) external pure returns (uint256) { return shares; }
    function getAPY(address) external pure returns (uint256) { return 500; }
    function isAvailable(address) external pure returns (bool) { return true; }
    function canRecall(address, uint256) external pure returns (bool) { return true; }
}

/// @dev Mock BalanceLedger for YieldRouter tests
contract MockLedgerForYR {
    mapping(address => mapping(address => uint256)) public available;
    function setAvailable(address user, address asset, uint256 amt) external { available[user][asset] = amt; }
    function getAvailable(address user, address asset) external view returns (uint256) { return available[user][asset]; }
    function moveToYieldRouter(address, address, uint256, uint256) external {}
    function moveFromYieldRouter(address, address, uint256, uint256) external {}
}

/// @title FinalGapsTest
/// @notice Tests for the last remaining gaps: expireIntent, withdrawFromReserve,
///         ProtocolTreasury expansion, FlowB fee check
contract FinalGapsTest is Test {
    MockToken public usdc;
    address owner = address(0x1);
    address user = address(0x10);

    function setUp() public {
        usdc = new MockToken("USD Coin", "USDC", 6, 0);
        usdc.mint(user, 100_000e6);
    }

    // ============ Test 1: CentuariRouter.expireIntent() ============

    function test_expireIntent_returns_tokens() public {
        CentuariRouter router = CentuariRouter(address(new TransparentUpgradeableProxy(
            address(new CentuariRouter()), owner,
            abi.encodeCall(CentuariRouter.initialize, (owner, address(0xE0)))
        )));

        vm.warp(100000);

        // User submits intent
        vm.startPrank(user);
        usdc.approve(address(router), 5000e6);
        bytes32 intentId = router.submitLendIntent(
            address(usdc), 5000e6, 500, 0, block.timestamp + 10 minutes, address(0)
        );
        vm.stopPrank();

        // Verify tokens in router
        assertEq(usdc.balanceOf(address(router)), 5000e6);

        // Warp past deadline
        vm.warp(block.timestamp + 11 minutes);

        // Anyone can call expireIntent
        router.expireIntent(intentId);

        // Tokens returned to user
        assertEq(usdc.balanceOf(user), 100_000e6, "Tokens returned after expiry");
        assertEq(usdc.balanceOf(address(router)), 0, "Router balance zero");

        // State is EXPIRED
        (ICentuariRouter.IntentState state,) = router.getIntentStatus(intentId);
        assertEq(uint8(state), uint8(ICentuariRouter.IntentState.EXPIRED));
    }

    function test_expireIntent_before_deadline_reverts() public {
        CentuariRouter router = CentuariRouter(address(new TransparentUpgradeableProxy(
            address(new CentuariRouter()), owner,
            abi.encodeCall(CentuariRouter.initialize, (owner, address(0xE0)))
        )));

        vm.warp(100000);

        vm.startPrank(user);
        usdc.approve(address(router), 1000e6);
        bytes32 intentId = router.submitLendIntent(
            address(usdc), 1000e6, 500, 0, block.timestamp + 1 hours, address(0)
        );
        vm.stopPrank();

        // Try to expire before deadline
        vm.expectRevert(bytes("CentuariRouter: not yet expired"));
        router.expireIntent(intentId);
    }

    // ============ Test 2: YieldRouter.withdrawFromReserve() ============

    function test_withdrawFromReserve_succeeds() public {
        MockLedgerForYR mockLedger = new MockLedgerForYR();
        MockAdapter adapter = new MockAdapter();

        YieldRouter router = YieldRouter(address(new TransparentUpgradeableProxy(
            address(new YieldRouter()), owner,
            abi.encodeCall(YieldRouter.initialize, (owner, address(mockLedger), owner))
        )));

        vm.warp(100000);
        vm.startPrank(owner);
        router.proposeAuthorizedCallerChange(address(this), true);
        vm.warp(100000 + 48 hours + 1);
        router.applyAuthorizedCallerChange(address(this));
        vm.stopPrank();

        // Deposit to reserve
        usdc.mint(address(this), 10_000e6);
        usdc.approve(address(router), 10_000e6);
        router.depositToReserve(address(usdc), 10_000e6);

        // Withdraw from reserve
        address recipient = address(0x99);
        router.withdrawFromReserve(address(usdc), 5_000e6, recipient);

        assertEq(usdc.balanceOf(recipient), 5_000e6, "Recipient received reserve funds");
    }

    function test_withdrawFromReserve_insufficient_reverts() public {
        MockLedgerForYR mockLedger = new MockLedgerForYR();

        YieldRouter router = YieldRouter(address(new TransparentUpgradeableProxy(
            address(new YieldRouter()), owner,
            abi.encodeCall(YieldRouter.initialize, (owner, address(mockLedger), owner))
        )));

        vm.warp(100000);
        vm.startPrank(owner);
        router.proposeAuthorizedCallerChange(address(this), true);
        vm.warp(100000 + 48 hours + 1);
        router.applyAuthorizedCallerChange(address(this));
        vm.stopPrank();

        // Try to withdraw without depositing
        vm.expectRevert(bytes("YieldRouter: insufficient reserve"));
        router.withdrawFromReserve(address(usdc), 1000e6, address(0x99));
    }

    // ============ Test 3: ProtocolTreasury expanded ============

    function test_protocolTreasury_zero_address_reverts() public {
        ProtocolTreasury treasury = ProtocolTreasury(address(new TransparentUpgradeableProxy(
            address(new ProtocolTreasury()), owner,
            abi.encodeCall(ProtocolTreasury.initialize, (owner, address(0xBEEF)))
        )));

        vm.prank(owner);
        vm.expectRevert(ProtocolTreasury.ZeroAddress.selector);
        treasury.withdrawFees(address(usdc), 1000e6, address(0));
    }

    function test_protocolTreasury_zero_amount_reverts() public {
        ProtocolTreasury treasury = ProtocolTreasury(address(new TransparentUpgradeableProxy(
            address(new ProtocolTreasury()), owner,
            abi.encodeCall(ProtocolTreasury.initialize, (owner, address(0xBEEF)))
        )));

        vm.prank(owner);
        vm.expectRevert(ProtocolTreasury.ZeroAmount.selector);
        treasury.withdrawFees(address(usdc), 0, address(0x99));
    }

    function test_protocolTreasury_non_owner_reverts() public {
        ProtocolTreasury treasury = ProtocolTreasury(address(new TransparentUpgradeableProxy(
            address(new ProtocolTreasury()), owner,
            abi.encodeCall(ProtocolTreasury.initialize, (owner, address(0xBEEF)))
        )));

        vm.prank(user);
        vm.expectRevert(); // OwnableUnauthorizedAccount
        treasury.withdrawFees(address(usdc), 1000e6, user);
    }

    function test_protocolTreasury_balanceLedger_view() public {
        address ledgerAddr = address(0xBEEF);
        ProtocolTreasury treasury = ProtocolTreasury(address(new TransparentUpgradeableProxy(
            address(new ProtocolTreasury()), owner,
            abi.encodeCall(ProtocolTreasury.initialize, (owner, ledgerAddr))
        )));

        assertEq(treasury.balanceLedger(), ledgerAddr);
    }
}
