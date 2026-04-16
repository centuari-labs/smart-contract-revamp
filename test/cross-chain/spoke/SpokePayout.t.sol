// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {SpokePayout} from "../../../src/core/cross-chain/spoke/SpokePayout.sol";
import {SpokeVaultStable} from "../../../src/core/cross-chain/spoke/SpokeVaultStable.sol";
import {ISpokePayout} from "../../../src/interfaces/cross-chain/spoke/ISpokePayout.sol";
import {ISpokeVaultStable} from "../../../src/interfaces/cross-chain/spoke/ISpokeVaultStable.sol";
import {MockToken} from "../../../src/mocks/MockToken.sol";
import {MockLZEndpoint} from "../../mocks/MockLZEndpoint.sol";

contract SpokePayoutTest is Test {
    SpokePayout internal payout;
    SpokeVaultStable internal vault;
    MockLZEndpoint internal lz;
    MockToken internal usdc; // BRIDGED
    MockToken internal xsgd; // SPOKE_NATIVE

    address internal owner = address(0xA11CE);
    address internal sweeperAddr = address(0x5EE9);
    address internal gatewayAddr = address(0xBEEF);
    address internal hubRegistry = address(0xABCD);
    address internal user = address(0x1111);
    address internal outsider = address(0xDEAD);

    uint32 internal constant SPOKE_EID = 30184;
    uint32 internal constant HUB_EID = 30110;
    uint8 internal constant BRIDGED = 1;
    uint8 internal constant SPOKE_NATIVE = 2;

    function setUp() public {
        usdc = new MockToken("USD Coin", "USDC", 6, 0);
        xsgd = new MockToken("XSGD", "XSGD", 6, 0);
        lz = new MockLZEndpoint(SPOKE_EID);

        // Deploy vault
        SpokeVaultStable vaultImpl = new SpokeVaultStable();
        bytes memory vaultInit = abi.encodeCall(
            SpokeVaultStable.initialize,
            (owner)
        );
        vault = SpokeVaultStable(
            address(
                new TransparentUpgradeableProxy(
                    address(vaultImpl),
                    address(this),
                    vaultInit
                )
            )
        );

        // Deploy payout
        SpokePayout payoutImpl = new SpokePayout();
        bytes memory payoutInit = abi.encodeCall(
            SpokePayout.initialize,
            (owner, address(vault), address(lz))
        );
        payout = SpokePayout(
            address(
                new TransparentUpgradeableProxy(
                    address(payoutImpl),
                    address(this),
                    payoutInit
                )
            )
        );

        // Wire roles
        vm.startPrank(owner);
        vault.setGateway(gatewayAddr);
        vault.setPayout(address(payout));
        vault.setSweeper(sweeperAddr);
        vault.setAssetClassification(
            address(usdc),
            ISpokeVaultStable.AssetClassification.BRIDGED
        );
        vault.setAssetClassification(
            address(xsgd),
            ISpokeVaultStable.AssetClassification.SPOKE_NATIVE
        );
        payout.setSweeper(sweeperAddr);
        payout.setPeer(HUB_EID, bytes32(uint256(uint160(hubRegistry))));
        vm.stopPrank();

        // Seed spoke-native custody in vault (simulate deposits).
        xsgd.mint(gatewayAddr, 1_000_000e6);
        vm.startPrank(gatewayAddr);
        xsgd.approve(address(vault), 1_000_000e6);
        vault.depositSpokeNative(address(xsgd), user, 100_000e6);
        vm.stopPrank();

        // Give sweeper USDC to replenish buffer.
        usdc.mint(sweeperAddr, 1_000_000e6);
    }

    // ============ Helpers ============

    function _deliverPayout(
        bytes32 requestId,
        address asset,
        uint256 amount,
        uint8 classification
    ) internal {
        bytes memory payload = abi.encode(
            requestId,
            user,
            asset,
            amount,
            classification
        );
        SpokePayout.Origin memory origin = SpokePayout.Origin({
            srcEid: HUB_EID,
            sender: bytes32(uint256(uint160(hubRegistry))),
            nonce: 1
        });
        vm.prank(address(lz));
        payout.lzReceive(
            origin,
            address(payout),
            bytes32(0),
            payload,
            bytes("")
        );
    }

    // ============ lzReceive — SPOKE_NATIVE ============

    function test_LzReceive_SpokeNative_ReleasesFromVault() public {
        bytes32 reqId = keccak256("spoke-native-payout-1");
        uint256 amount = 50e6;
        uint256 userBefore = xsgd.balanceOf(user);

        _deliverPayout(reqId, address(xsgd), amount, SPOKE_NATIVE);

        assertEq(xsgd.balanceOf(user), userBefore + amount);
        assertEq(vault.spokeNativeBalance(address(xsgd)), 100_000e6 - amount);
    }

    // ============ lzReceive — BRIDGED with buffer ============

    function test_LzReceive_Bridged_ImmediateRelease() public {
        // Replenish buffer first.
        vm.startPrank(sweeperAddr);
        usdc.approve(address(payout), 100e6);
        payout.replenishBridgedBuffer(address(usdc), 100e6);
        vm.stopPrank();

        bytes32 reqId = keccak256("bridged-payout-1");
        uint256 userBefore = usdc.balanceOf(user);

        _deliverPayout(reqId, address(usdc), 50e6, BRIDGED);

        assertEq(usdc.balanceOf(user), userBefore + 50e6);
        assertEq(payout.bridgedBuffer(address(usdc)), 50e6);
    }

    // ============ lzReceive — BRIDGED without buffer (queued) ============

    function test_LzReceive_Bridged_Queued() public {
        bytes32 reqId = keccak256("bridged-queued-1");

        _deliverPayout(reqId, address(usdc), 50e6, BRIDGED);

        assertEq(payout.pendingPayoutCount(user, address(usdc)), 1);
        assertEq(usdc.balanceOf(user), 0); // no immediate payout
    }

    // ============ replenishBridgedBuffer ============

    function test_ReplenishBridgedBuffer_HappyPath() public {
        vm.startPrank(sweeperAddr);
        usdc.approve(address(payout), 100e6);
        vm.expectEmit(true, false, false, true);
        emit ISpokePayout.BridgedBufferReplenished(address(usdc), 100e6, 100e6);
        payout.replenishBridgedBuffer(address(usdc), 100e6);
        vm.stopPrank();

        assertEq(payout.bridgedBuffer(address(usdc)), 100e6);
        assertEq(usdc.balanceOf(address(payout)), 100e6);
    }

    function test_ReplenishBridgedBuffer_OnlySweeper() public {
        vm.prank(outsider);
        vm.expectRevert(ISpokePayout.Unauthorized.selector);
        payout.replenishBridgedBuffer(address(usdc), 1);
    }

    function test_ReplenishBridgedBuffer_RevertZeroAmount() public {
        vm.prank(sweeperAddr);
        vm.expectRevert(ISpokePayout.ZeroAmount.selector);
        payout.replenishBridgedBuffer(address(usdc), 0);
    }

    // ============ flushPending ============

    function test_FlushPending_DrainsFully() public {
        // Queue two payouts.
        _deliverPayout(keccak256("q1"), address(usdc), 30e6, BRIDGED);
        _deliverPayout(keccak256("q2"), address(usdc), 20e6, BRIDGED);
        assertEq(payout.pendingPayoutCount(user, address(usdc)), 2);

        // Replenish enough for both.
        vm.startPrank(sweeperAddr);
        usdc.approve(address(payout), 100e6);
        payout.replenishBridgedBuffer(address(usdc), 100e6);
        vm.stopPrank();

        payout.flushPending(user, address(usdc));

        assertEq(payout.pendingPayoutCount(user, address(usdc)), 0);
        assertEq(usdc.balanceOf(user), 50e6);
        assertEq(payout.bridgedBuffer(address(usdc)), 50e6);
    }

    function test_FlushPending_PartialFlush() public {
        _deliverPayout(keccak256("q1"), address(usdc), 60e6, BRIDGED);
        _deliverPayout(keccak256("q2"), address(usdc), 50e6, BRIDGED);

        // Only replenish enough for the first.
        vm.startPrank(sweeperAddr);
        usdc.approve(address(payout), 60e6);
        payout.replenishBridgedBuffer(address(usdc), 60e6);
        vm.stopPrank();

        payout.flushPending(user, address(usdc));

        assertEq(payout.pendingPayoutCount(user, address(usdc)), 1);
        assertEq(usdc.balanceOf(user), 60e6);
        assertEq(payout.bridgedBuffer(address(usdc)), 0);
    }

    function test_FlushPending_RevertNoPending() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ISpokePayout.NoPendingPayouts.selector,
                user,
                address(usdc)
            )
        );
        payout.flushPending(user, address(usdc));
    }

    // ============ Access control ============

    function test_LzReceive_RevertInvalidEndpoint() public {
        bytes memory payload = abi.encode(
            keccak256("x"),
            user,
            address(usdc),
            100e6,
            BRIDGED
        );
        SpokePayout.Origin memory origin = SpokePayout.Origin({
            srcEid: HUB_EID,
            sender: bytes32(uint256(uint160(hubRegistry))),
            nonce: 1
        });
        vm.prank(outsider);
        vm.expectRevert(ISpokePayout.InvalidLzEndpoint.selector);
        payout.lzReceive(
            origin,
            address(payout),
            bytes32(0),
            payload,
            bytes("")
        );
    }

    function test_LzReceive_RevertUntrustedRemote() public {
        bytes memory payload = abi.encode(
            keccak256("x"),
            user,
            address(usdc),
            100e6,
            BRIDGED
        );
        SpokePayout.Origin memory origin = SpokePayout.Origin({
            srcEid: HUB_EID,
            sender: bytes32(uint256(uint160(outsider))),
            nonce: 1
        });
        vm.prank(address(lz));
        vm.expectRevert(
            abi.encodeWithSelector(
                ISpokePayout.UntrustedRemote.selector,
                HUB_EID,
                bytes32(uint256(uint160(outsider)))
            )
        );
        payout.lzReceive(
            origin,
            address(payout),
            bytes32(0),
            payload,
            bytes("")
        );
    }

    // ============ Admin ============

    function test_Admin_SettersOwnerOnly() public {
        vm.startPrank(outsider);
        vm.expectRevert();
        payout.setVault(address(0xCAFE));
        vm.expectRevert();
        payout.setSweeper(address(0xCAFE));
        vm.expectRevert();
        payout.setEndpoint(address(0xCAFE));
        vm.expectRevert();
        payout.setPeer(HUB_EID, bytes32(uint256(1)));
        vm.stopPrank();
    }

    function test_Views() public view {
        assertEq(payout.vault(), address(vault));
        assertEq(payout.sweeper(), sweeperAddr);
        assertEq(payout.endpoint(), address(lz));
        assertEq(
            payout.peers(HUB_EID),
            bytes32(uint256(uint160(hubRegistry)))
        );
    }
}
