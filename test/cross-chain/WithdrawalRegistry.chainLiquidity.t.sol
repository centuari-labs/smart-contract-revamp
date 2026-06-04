// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {BalanceLedger} from "../../src/core/balance-ledger/BalanceLedger.sol";
import {HubDepositor} from "../../src/core/cross-chain/HubDepositor.sol";
import {WithdrawalRegistry} from "../../src/core/cross-chain/WithdrawalRegistry.sol";
import {MockRiskModule} from "../mocks/MockRiskModule.sol";
import {IWithdrawalRegistry} from "../../src/interfaces/cross-chain/IWithdrawalRegistry.sol";
import {MockToken} from "../../src/mocks/MockToken.sol";

contract WithdrawalRegistryChainLiquidityTest is Test {
    BalanceLedger internal ledger;
    HubDepositor internal depositor;
    WithdrawalRegistry internal registry;
    MockRiskModule internal riskModule;
    MockToken internal usdc; // BRIDGED — no spoke-native route
    MockToken internal xsgd; // SPOKE_NATIVE

    address internal owner = address(0xA11CE);
    address internal operatorAddr = address(0x0BEE);
    address internal settlerAddr = address(0x5E77); // mock HubIntentSettler
    address internal user = address(0x1111);
    address internal outsider = address(0xDEAD);

    uint256 internal constant INITIAL_MINT = 1_000_000e6;
    uint256 internal constant DEPOSIT_AMOUNT = 100_000e6;
    uint256 internal constant BASE_CHAIN_ID = 8453;

    function setUp() public {
        usdc = new MockToken("USD Coin", "USDC", 6, 0);
        xsgd = new MockToken("XSGD", "XSGD", 6, 0);

        // Deploy BalanceLedger
        BalanceLedger ledgerImpl = new BalanceLedger();
        bytes memory ledgerInit = abi.encodeCall(BalanceLedger.initialize, (owner, true));
        TransparentUpgradeableProxy ledgerProxy =
            new TransparentUpgradeableProxy(address(ledgerImpl), address(this), ledgerInit);
        ledger = BalanceLedger(address(ledgerProxy));

        // Deploy HubDepositor
        HubDepositor depositorImpl = new HubDepositor();
        bytes memory depositorInit = abi.encodeCall(HubDepositor.initialize, (owner, address(ledger)));
        TransparentUpgradeableProxy depositorProxy =
            new TransparentUpgradeableProxy(address(depositorImpl), address(this), depositorInit);
        depositor = HubDepositor(address(depositorProxy));

        riskModule = new MockRiskModule();

        // Deploy WithdrawalRegistry
        WithdrawalRegistry regImpl = new WithdrawalRegistry();
        bytes memory regInit = abi.encodeCall(
            WithdrawalRegistry.initialize,
            (owner, operatorAddr, address(ledger), address(riskModule), address(depositor))
        );
        TransparentUpgradeableProxy regProxy = new TransparentUpgradeableProxy(address(regImpl), address(this), regInit);
        registry = WithdrawalRegistry(address(regProxy));

        // Wire
        vm.startPrank(owner);
        ledger.forceAddWriter(address(depositor));
        ledger.forceAddWriter(address(registry));
        depositor.addSupportedAsset(address(usdc));
        depositor.addSupportedAsset(address(xsgd));
        depositor.setAuthorizedCaller(address(registry), true);
        registry.setHubIntentSettler(settlerAddr);
        registry.setSpokeNativeRoute(address(xsgd), BASE_CHAIN_ID, true);
        vm.stopPrank();

        // Seed user balances via HubDepositor
        usdc.mint(user, INITIAL_MINT);
        xsgd.mint(user, INITIAL_MINT);
        vm.startPrank(user);
        usdc.approve(address(depositor), DEPOSIT_AMOUNT);
        depositor.deposit(address(usdc), DEPOSIT_AMOUNT);
        xsgd.approve(address(depositor), DEPOSIT_AMOUNT);
        depositor.deposit(address(xsgd), DEPOSIT_AMOUNT);
        vm.stopPrank();
    }

    // ============ incrementChainLiquidity ============

    function test_IncrementChainLiquidity_HappyPath() public {
        vm.prank(settlerAddr);
        vm.expectEmit(true, true, false, true);
        emit IWithdrawalRegistry.ChainLiquidityIncremented(address(xsgd), BASE_CHAIN_ID, 50e6, 50e6);
        registry.incrementChainLiquidity(address(xsgd), BASE_CHAIN_ID, 50e6);

        assertEq(registry.chainLiquidity(address(xsgd), BASE_CHAIN_ID), 50e6);
    }

    function test_IncrementChainLiquidity_Accumulates() public {
        vm.startPrank(settlerAddr);
        registry.incrementChainLiquidity(address(xsgd), BASE_CHAIN_ID, 30e6);
        registry.incrementChainLiquidity(address(xsgd), BASE_CHAIN_ID, 20e6);
        vm.stopPrank();

        assertEq(registry.chainLiquidity(address(xsgd), BASE_CHAIN_ID), 50e6);
    }

    function test_IncrementChainLiquidity_RevertUnauthorized() public {
        vm.prank(outsider);
        vm.expectRevert(IWithdrawalRegistry.Unauthorized.selector);
        registry.incrementChainLiquidity(address(xsgd), BASE_CHAIN_ID, 1);
    }

    function test_IncrementChainLiquidity_RevertZeroAmount() public {
        vm.prank(settlerAddr);
        vm.expectRevert(IWithdrawalRegistry.ZeroAmount.selector);
        registry.incrementChainLiquidity(address(xsgd), BASE_CHAIN_ID, 0);
    }

    // ============ requestWithdrawal — SPOKE_NATIVE capacity gate ============

    function test_RequestWithdrawal_SpokeNative_Succeeds() public {
        // Seed liquidity.
        vm.prank(settlerAddr);
        registry.incrementChainLiquidity(address(xsgd), BASE_CHAIN_ID, 50e6);

        // Withdraw within liquidity.
        vm.prank(user);
        bytes32 reqId = registry.requestWithdrawal(address(xsgd), 50e6, BASE_CHAIN_ID);

        assertTrue(reqId != bytes32(0));
        // Liquidity fully decremented.
        assertEq(registry.chainLiquidity(address(xsgd), BASE_CHAIN_ID), 0);
        // Ledger debited.
        assertEq(ledger.available(user, address(xsgd)), DEPOSIT_AMOUNT - 50e6);
    }

    function test_RequestWithdrawal_SpokeNative_PartialDecrement() public {
        vm.prank(settlerAddr);
        registry.incrementChainLiquidity(address(xsgd), BASE_CHAIN_ID, 100e6);

        vm.prank(user);
        registry.requestWithdrawal(address(xsgd), 30e6, BASE_CHAIN_ID);

        assertEq(registry.chainLiquidity(address(xsgd), BASE_CHAIN_ID), 70e6);
    }

    function test_RequestWithdrawal_SpokeNative_RevertInsufficient() public {
        vm.prank(settlerAddr);
        registry.incrementChainLiquidity(address(xsgd), BASE_CHAIN_ID, 10e6);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                IWithdrawalRegistry.InsufficientChainLiquidity.selector, address(xsgd), BASE_CHAIN_ID, 10e6, 50e6
            )
        );
        registry.requestWithdrawal(address(xsgd), 50e6, BASE_CHAIN_ID);
    }

    function test_RequestWithdrawal_SpokeNative_RevertZeroLiquidity() public {
        // No liquidity seeded.
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                IWithdrawalRegistry.InsufficientChainLiquidity.selector, address(xsgd), BASE_CHAIN_ID, 0, 10e6
            )
        );
        registry.requestWithdrawal(address(xsgd), 10e6, BASE_CHAIN_ID);
    }

    // ============ requestWithdrawal — BRIDGED (no capacity gate) ============

    function test_RequestWithdrawal_Bridged_BypassesCapacityGate() public {
        // USDC on Base is NOT marked spoke-native → no capacity check.
        // Zero chain liquidity, should still succeed.
        assertEq(registry.chainLiquidity(address(usdc), BASE_CHAIN_ID), 0);

        vm.prank(user);
        bytes32 reqId = registry.requestWithdrawal(address(usdc), 10e6, BASE_CHAIN_ID);
        assertTrue(reqId != bytes32(0));
    }

    function test_RequestWithdrawal_HubNative_BypassesCapacityGate() public {
        // Hub-native withdrawal (targetChainId == block.chainid) — no route
        // is flagged spoke-native for the hub chain, so capacity gate is a no-op.
        vm.prank(user);
        bytes32 reqId = registry.requestWithdrawal(address(usdc), 10e6, block.chainid);
        assertTrue(reqId != bytes32(0));
    }

    // ============ markFailed — SPOKE_NATIVE chain-liquidity restore ============

    function test_MarkFailed_SpokeNative_RestoresChainLiquidity() public {
        // Seed liquidity, then withdraw the whole amount (decrements to 0).
        uint256 seeded = 50e6;
        vm.prank(settlerAddr);
        registry.incrementChainLiquidity(address(xsgd), BASE_CHAIN_ID, seeded);

        vm.prank(user);
        bytes32 reqId = registry.requestWithdrawal(address(xsgd), seeded, BASE_CHAIN_ID);

        // Pre-conditions: liquidity spent, balance debited.
        assertEq(registry.chainLiquidity(address(xsgd), BASE_CHAIN_ID), 0);
        assertEq(ledger.available(user, address(xsgd)), DEPOSIT_AMOUNT - seeded);

        // Fail the withdrawal — no physical liquidity was spent, so the
        // counter must be restored to its pre-request value.
        vm.prank(operatorAddr);
        registry.markFailed(reqId);

        assertEq(registry.chainLiquidity(address(xsgd), BASE_CHAIN_ID), seeded);
        // Balance is also credited back.
        assertEq(ledger.available(user, address(xsgd)), DEPOSIT_AMOUNT);
    }

    function test_MarkFailed_SpokeNative_EmitsRestoreEvent() public {
        uint256 seeded = 40e6;
        vm.prank(settlerAddr);
        registry.incrementChainLiquidity(address(xsgd), BASE_CHAIN_ID, seeded);

        vm.prank(user);
        bytes32 reqId = registry.requestWithdrawal(address(xsgd), seeded, BASE_CHAIN_ID);

        vm.prank(operatorAddr);
        vm.expectEmit(true, true, true, true);
        emit IWithdrawalRegistry.ChainLiquidityRestored(address(xsgd), BASE_CHAIN_ID, reqId, seeded, seeded);
        registry.markFailed(reqId);
    }

    function test_MarkFailed_SpokeNative_PartialRoundTrip() public {
        // Seed more than the withdrawal so a remainder stays after the debit,
        // and the restore lands back exactly on the seeded value.
        vm.prank(settlerAddr);
        registry.incrementChainLiquidity(address(xsgd), BASE_CHAIN_ID, 100e6);

        vm.prank(user);
        bytes32 reqId = registry.requestWithdrawal(address(xsgd), 30e6, BASE_CHAIN_ID);
        assertEq(registry.chainLiquidity(address(xsgd), BASE_CHAIN_ID), 70e6);

        vm.prank(operatorAddr);
        registry.markFailed(reqId);
        assertEq(registry.chainLiquidity(address(xsgd), BASE_CHAIN_ID), 100e6);
    }

    function test_MarkFailed_Bridged_DoesNotTouchChainLiquidity() public {
        // BRIDGED route never decremented chain liquidity, so a failure must
        // not spuriously inflate it.
        vm.prank(user);
        bytes32 reqId = registry.requestWithdrawal(address(usdc), 10e6, BASE_CHAIN_ID);
        assertEq(registry.chainLiquidity(address(usdc), BASE_CHAIN_ID), 0);

        vm.prank(operatorAddr);
        registry.markFailed(reqId);

        assertEq(registry.chainLiquidity(address(usdc), BASE_CHAIN_ID), 0);
        // Balance still credited back.
        assertEq(ledger.available(user, address(usdc)), DEPOSIT_AMOUNT);
    }

    // ============ Admin ============

    function test_SetHubIntentSettler_OwnerOnly() public {
        vm.prank(outsider);
        vm.expectRevert();
        registry.setHubIntentSettler(address(0xCAFE));
    }

    function test_SetSpokeNativeRoute_OwnerOnly() public {
        vm.prank(outsider);
        vm.expectRevert();
        registry.setSpokeNativeRoute(address(xsgd), BASE_CHAIN_ID, false);
    }

    function test_SetSpokeNativeRoute_RevertZeroAsset() public {
        vm.prank(owner);
        vm.expectRevert(IWithdrawalRegistry.ZeroAddress.selector);
        registry.setSpokeNativeRoute(address(0), BASE_CHAIN_ID, true);
    }

    function test_SetSpokeNativeRoute_ToggleOff() public {
        assertTrue(registry.isSpokeNativeRoute(address(xsgd), BASE_CHAIN_ID));

        vm.prank(owner);
        registry.setSpokeNativeRoute(address(xsgd), BASE_CHAIN_ID, false);

        assertFalse(registry.isSpokeNativeRoute(address(xsgd), BASE_CHAIN_ID));

        // Now withdrawal succeeds without liquidity (route no longer spoke-native).
        vm.prank(user);
        bytes32 reqId = registry.requestWithdrawal(address(xsgd), 10e6, BASE_CHAIN_ID);
        assertTrue(reqId != bytes32(0));
    }

    function test_Views_ReturnCorrectValues() public view {
        assertEq(registry.hubIntentSettler(), settlerAddr);
        assertTrue(registry.isSpokeNativeRoute(address(xsgd), BASE_CHAIN_ID));
        assertFalse(registry.isSpokeNativeRoute(address(usdc), BASE_CHAIN_ID));
    }
}
