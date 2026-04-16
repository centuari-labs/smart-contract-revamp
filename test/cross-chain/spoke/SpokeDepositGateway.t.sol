// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, Vm} from "forge-std/Test.sol";
import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {SpokeVaultStable} from "../../../src/core/cross-chain/spoke/SpokeVaultStable.sol";
import {SpokeDepositGateway} from "../../../src/core/cross-chain/spoke/SpokeDepositGateway.sol";
import {ISpokeVaultStable} from "../../../src/interfaces/cross-chain/spoke/ISpokeVaultStable.sol";
import {ISpokeDepositGateway} from "../../../src/interfaces/cross-chain/spoke/ISpokeDepositGateway.sol";
import {MockToken} from "../../../src/mocks/MockToken.sol";
import {MockLZEndpoint} from "../../mocks/MockLZEndpoint.sol";

contract SpokeDepositGatewayTest is Test {
    SpokeVaultStable internal vault;
    SpokeDepositGateway internal gateway;
    MockLZEndpoint internal lz;
    MockToken internal usdc; // BRIDGED
    MockToken internal xsgd; // SPOKE_NATIVE

    address internal owner = address(0xA11CE);
    address internal user = address(0x1111);
    address internal outsider = address(0xDEAD);
    address internal hubPeer = address(0xB0B0);

    uint32 internal constant SPOKE_EID = 30184; // arbitrary
    uint32 internal constant HUB_EID = 30110; // Arbitrum One Stargate eid

    uint256 internal constant INITIAL_MINT = 1_000_000e6;

    function setUp() public {
        usdc = new MockToken("USD Coin", "USDC", 6, 0);
        xsgd = new MockToken("XSGD", "XSGD", 6, 0);
        lz = new MockLZEndpoint(SPOKE_EID);

        SpokeVaultStable vaultImpl = new SpokeVaultStable();
        bytes memory vaultInit = abi.encodeCall(
            SpokeVaultStable.initialize,
            (owner)
        );
        TransparentUpgradeableProxy vaultProxy = new TransparentUpgradeableProxy(
            address(vaultImpl),
            address(this),
            vaultInit
        );
        vault = SpokeVaultStable(address(vaultProxy));

        SpokeDepositGateway gwImpl = new SpokeDepositGateway();
        bytes memory gwInit = abi.encodeCall(
            SpokeDepositGateway.initialize,
            (owner, address(vault), address(lz), HUB_EID)
        );
        TransparentUpgradeableProxy gwProxy = new TransparentUpgradeableProxy(
            address(gwImpl),
            address(this),
            gwInit
        );
        gateway = SpokeDepositGateway(address(gwProxy));

        // Wire roles + classifications + peer.
        vm.startPrank(owner);
        vault.setGateway(address(gateway));
        vault.setAssetClassification(
            address(usdc),
            ISpokeVaultStable.AssetClassification.BRIDGED
        );
        vault.setAssetClassification(
            address(xsgd),
            ISpokeVaultStable.AssetClassification.SPOKE_NATIVE
        );
        gateway.setAssetClassification(
            address(usdc),
            ISpokeVaultStable.AssetClassification.BRIDGED
        );
        gateway.setAssetClassification(
            address(xsgd),
            ISpokeVaultStable.AssetClassification.SPOKE_NATIVE
        );
        gateway.setPeer(HUB_EID, _addr(hubPeer));
        vm.stopPrank();

        usdc.mint(user, INITIAL_MINT);
        xsgd.mint(user, INITIAL_MINT);
        vm.deal(user, 100 ether);
    }

    function _addr(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    // ============ Initialization ============

    function test_Initialize_StoresWiring() public view {
        assertEq(gateway.owner(), owner);
        assertEq(gateway.vault(), address(vault));
        assertEq(gateway.endpoint(), address(lz));
        assertEq(gateway.hubEid(), HUB_EID);
        assertEq(gateway.peers(HUB_EID), _addr(hubPeer));
        assertEq(gateway.REFUND_WINDOW(), 30 minutes);
    }

    function test_Initialize_RevertZeroVault() public {
        SpokeDepositGateway impl = new SpokeDepositGateway();
        bytes memory bad = abi.encodeCall(
            SpokeDepositGateway.initialize,
            (owner, address(0), address(lz), HUB_EID)
        );
        vm.expectRevert(ISpokeDepositGateway.ZeroAddress.selector);
        new TransparentUpgradeableProxy(address(impl), address(this), bad);
    }

    function test_Initialize_RevertZeroEndpoint() public {
        SpokeDepositGateway impl = new SpokeDepositGateway();
        bytes memory bad = abi.encodeCall(
            SpokeDepositGateway.initialize,
            (owner, address(vault), address(0), HUB_EID)
        );
        vm.expectRevert(ISpokeDepositGateway.ZeroAddress.selector);
        new TransparentUpgradeableProxy(address(impl), address(this), bad);
    }

    // ============ deposit (BRIDGED) ============

    function test_DepositBridged_HappyPath() public {
        uint256 amount = 100e6;
        uint256 fee = lz.nativeFee();

        vm.startPrank(user);
        usdc.approve(address(gateway), amount);
        bytes32 depositId = gateway.deposit{value: fee}(address(usdc), amount);
        vm.stopPrank();

        // Vault holds the escrow under bridged custody.
        assertEq(vault.bridgedBalance(address(usdc)), amount);
        assertEq(usdc.balanceOf(address(vault)), amount);
        // User nonce bumped.
        assertEq(gateway.userNonce(user), 1);
        // Deterministic id.
        assertEq(
            depositId,
            keccak256(abi.encode(block.chainid, user, uint256(0)))
        );
        // Pending state persisted.
        ISpokeDepositGateway.PendingDeposit memory pd = gateway
            .pendingDeposit(depositId);
        assertEq(pd.user, user);
        assertEq(pd.asset, address(usdc));
        assertEq(pd.amount, amount);
        assertEq(
            uint8(pd.classification),
            uint8(ISpokeVaultStable.AssetClassification.BRIDGED)
        );
        assertEq(pd.timestamp, uint64(block.timestamp));
        assertFalse(pd.refunded);
        // LZ packet captured.
        assertEq(lz.packetCount(), 1);
        MockLZEndpoint.CapturedPacket memory pkt = lz.packetAt(0);
        assertEq(pkt.dstEid, HUB_EID);
        assertEq(pkt.receiver, _addr(hubPeer));
        // Payload schema check.
        (
            bytes32 payloadDepositId,
            address payloadUser,
            address payloadAsset,
            uint256 payloadAmount,
            uint8 payloadCls,
            uint256 payloadChainId
        ) = abi.decode(
                pkt.message,
                (bytes32, address, address, uint256, uint8, uint256)
            );
        assertEq(payloadDepositId, depositId);
        assertEq(payloadUser, user);
        assertEq(payloadAsset, address(usdc));
        assertEq(payloadAmount, amount);
        assertEq(
            payloadCls,
            uint8(ISpokeVaultStable.AssetClassification.BRIDGED)
        );
        assertEq(payloadChainId, block.chainid);
    }

    function test_DepositBridged_EmitsEvent() public {
        uint256 amount = 100e6;
        uint256 fee = lz.nativeFee();
        vm.startPrank(user);
        usdc.approve(address(gateway), amount);
        // Don't constrain the guid topic — value depends on internal counter.
        vm.recordLogs();
        gateway.deposit{value: fee}(address(usdc), amount);
        vm.stopPrank();
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bool found;
        bytes32 depositInitiatedSig = keccak256(
            "DepositInitiated(bytes32,address,address,uint256,uint32,bytes32)"
        );
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == depositInitiatedSig) {
                found = true;
                break;
            }
        }
        assertTrue(found, "DepositInitiated not emitted");
    }

    function test_DepositBridged_PullsTokensFromUser() public {
        uint256 amount = 100e6;
        uint256 fee = lz.nativeFee();
        uint256 before = usdc.balanceOf(user);

        vm.startPrank(user);
        usdc.approve(address(gateway), amount);
        gateway.deposit{value: fee}(address(usdc), amount);
        vm.stopPrank();

        assertEq(usdc.balanceOf(user), before - amount);
    }

    function test_DepositBridged_NonceMonotonic() public {
        uint256 amount = 100e6;
        uint256 fee = lz.nativeFee();
        vm.startPrank(user);
        usdc.approve(address(gateway), amount * 3);
        bytes32 id0 = gateway.deposit{value: fee}(address(usdc), amount);
        bytes32 id1 = gateway.deposit{value: fee}(address(usdc), amount);
        bytes32 id2 = gateway.deposit{value: fee}(address(usdc), amount);
        vm.stopPrank();
        assertTrue(id0 != id1 && id1 != id2);
        assertEq(gateway.userNonce(user), 3);
        assertEq(lz.packetCount(), 3);
    }

    // ============ deposit (SPOKE_NATIVE) ============

    function test_DepositSpokeNative_HappyPath() public {
        uint256 amount = 50e6;
        uint256 fee = lz.nativeFee();
        vm.startPrank(user);
        xsgd.approve(address(gateway), amount);
        bytes32 depositId = gateway.deposit{value: fee}(address(xsgd), amount);
        vm.stopPrank();

        assertEq(vault.spokeNativeBalance(address(xsgd)), amount);
        ISpokeDepositGateway.PendingDeposit memory pd = gateway
            .pendingDeposit(depositId);
        assertEq(
            uint8(pd.classification),
            uint8(ISpokeVaultStable.AssetClassification.SPOKE_NATIVE)
        );
        // Payload classification byte.
        MockLZEndpoint.CapturedPacket memory pkt = lz.packetAt(0);
        (, , , , uint8 cls, ) = abi.decode(
            pkt.message,
            (bytes32, address, address, uint256, uint8, uint256)
        );
        assertEq(
            cls,
            uint8(ISpokeVaultStable.AssetClassification.SPOKE_NATIVE)
        );
    }

    // ============ deposit reverts ============

    function test_Deposit_RevertZeroAsset() public {
        vm.prank(user);
        vm.expectRevert(ISpokeDepositGateway.ZeroAddress.selector);
        gateway.deposit(address(0), 1);
    }

    function test_Deposit_RevertZeroAmount() public {
        vm.prank(user);
        vm.expectRevert(ISpokeDepositGateway.ZeroAmount.selector);
        gateway.deposit(address(usdc), 0);
    }

    function test_Deposit_RevertUnsupportedAsset() public {
        MockToken stray = new MockToken("Stray", "STRAY", 18, 0);
        stray.mint(user, 1e18);
        vm.startPrank(user);
        stray.approve(address(gateway), 1e18);
        vm.expectRevert(ISpokeDepositGateway.UnsupportedAsset.selector);
        gateway.deposit(address(stray), 1e18);
        vm.stopPrank();
    }

    function test_Deposit_RevertPeerNotSet() public {
        // Wipe the peer.
        vm.prank(owner);
        gateway.setPeer(HUB_EID, bytes32(0));
        vm.startPrank(user);
        usdc.approve(address(gateway), 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISpokeDepositGateway.PeerNotSet.selector,
                HUB_EID
            )
        );
        gateway.deposit(address(usdc), 1);
        vm.stopPrank();
    }

    function test_Deposit_RevertInsufficientFee() public {
        uint256 amount = 100e6;
        uint256 fee = lz.nativeFee();
        vm.startPrank(user);
        usdc.approve(address(gateway), amount);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISpokeDepositGateway.InsufficientLzFee.selector,
                0,
                fee
            )
        );
        gateway.deposit(address(usdc), amount);
        vm.stopPrank();
    }

    function test_Deposit_RefundsExcessNative() public {
        uint256 amount = 100e6;
        uint256 fee = lz.nativeFee();
        uint256 sent = fee + 0.5 ether;
        uint256 balanceBefore = user.balance;

        vm.startPrank(user);
        usdc.approve(address(gateway), amount);
        gateway.deposit{value: sent}(address(usdc), amount);
        vm.stopPrank();

        // The user paid only the LZ fee; the excess was refunded.
        assertEq(user.balance, balanceBefore - fee);
    }

    // ============ refund ============

    function test_Refund_HappyPathAfterWindow() public {
        uint256 amount = 100e6;
        uint256 fee = lz.nativeFee();
        vm.startPrank(user);
        usdc.approve(address(gateway), amount);
        bytes32 depositId = gateway.deposit{value: fee}(address(usdc), amount);
        vm.stopPrank();

        vm.warp(block.timestamp + 30 minutes + 1);

        uint256 userBalanceBefore = usdc.balanceOf(user);

        vm.prank(user);
        vm.expectEmit(true, true, true, true);
        emit ISpokeDepositGateway.DepositRefunded(
            depositId,
            user,
            address(usdc),
            amount
        );
        gateway.refund(depositId);

        assertEq(usdc.balanceOf(user), userBalanceBefore + amount);
        assertEq(vault.bridgedBalance(address(usdc)), 0);
        ISpokeDepositGateway.PendingDeposit memory pd = gateway.pendingDeposit(
            depositId
        );
        assertTrue(pd.refunded);
    }

    function test_Refund_RevertBeforeWindow() public {
        uint256 fee = lz.nativeFee();
        vm.startPrank(user);
        usdc.approve(address(gateway), 100e6);
        bytes32 depositId = gateway.deposit{value: fee}(address(usdc), 100e6);
        vm.stopPrank();

        uint64 unlockAt = uint64(block.timestamp) + 30 minutes;
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISpokeDepositGateway.RefundNotYetAllowed.selector,
                unlockAt
            )
        );
        gateway.refund(depositId);
    }

    function test_Refund_RevertSpokeNative() public {
        uint256 fee = lz.nativeFee();
        vm.startPrank(user);
        xsgd.approve(address(gateway), 100e6);
        bytes32 depositId = gateway.deposit{value: fee}(address(xsgd), 100e6);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 hours);
        vm.prank(user);
        vm.expectRevert(
            ISpokeDepositGateway.RefundNotPermittedForSpokeNative.selector
        );
        gateway.refund(depositId);
    }

    function test_Refund_RevertUnknownDeposit() public {
        vm.prank(user);
        vm.expectRevert(ISpokeDepositGateway.UnknownDeposit.selector);
        gateway.refund(bytes32(uint256(0xCAFE)));
    }

    function test_Refund_RevertNotOriginalDepositor() public {
        uint256 fee = lz.nativeFee();
        vm.startPrank(user);
        usdc.approve(address(gateway), 100e6);
        bytes32 depositId = gateway.deposit{value: fee}(address(usdc), 100e6);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 hours);
        vm.prank(outsider);
        vm.expectRevert(ISpokeDepositGateway.NotOriginalDepositor.selector);
        gateway.refund(depositId);
    }

    function test_Refund_RevertAlreadyRefunded() public {
        uint256 fee = lz.nativeFee();
        vm.startPrank(user);
        usdc.approve(address(gateway), 100e6);
        bytes32 depositId = gateway.deposit{value: fee}(address(usdc), 100e6);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 hours);
        vm.prank(user);
        gateway.refund(depositId);

        vm.prank(user);
        vm.expectRevert(ISpokeDepositGateway.AlreadyRefunded.selector);
        gateway.refund(depositId);
    }

    // ============ admin ============

    function test_SetPeer_OwnerOnly() public {
        vm.prank(outsider);
        vm.expectRevert();
        gateway.setPeer(HUB_EID, _addr(outsider));
    }

    function test_SetVault_OwnerOnly() public {
        vm.prank(outsider);
        vm.expectRevert();
        gateway.setVault(address(0xCAFE));
    }

    function test_SetVault_RevertZero() public {
        vm.prank(owner);
        vm.expectRevert(ISpokeDepositGateway.ZeroAddress.selector);
        gateway.setVault(address(0));
    }

    function test_SetEndpoint_RevertZero() public {
        vm.prank(owner);
        vm.expectRevert(ISpokeDepositGateway.ZeroAddress.selector);
        gateway.setEndpoint(address(0));
    }

    function test_QuoteDeposit_ReturnsLzFee() public view {
        uint256 fee = gateway.quoteDeposit(address(usdc), 100e6);
        assertEq(fee, lz.nativeFee());
    }
}

