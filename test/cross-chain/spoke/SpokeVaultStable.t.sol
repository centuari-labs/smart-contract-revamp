// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {SpokeVaultStable} from "../../../src/core/cross-chain/spoke/SpokeVaultStable.sol";
import {ISpokeVaultStable} from "../../../src/interfaces/cross-chain/spoke/ISpokeVaultStable.sol";
import {MockToken} from "../../../src/mocks/MockToken.sol";
import {MockCCTPMessenger} from "../../mocks/MockCCTPMessenger.sol";
import {MockStargateRouter} from "../../mocks/MockStargateRouter.sol";

contract SpokeVaultStableTest is Test {
    SpokeVaultStable internal vault;
    MockToken internal usdc;          // BRIDGED
    MockToken internal xsgd;          // SPOKE_NATIVE
    MockToken internal weth;          // BRIDGED, no Stargate router set (negative tests)
    MockCCTPMessenger internal cctp;
    MockStargateRouter internal stargateUsdc;

    address internal owner = address(0xA11CE);
    address internal gateway = address(0xBEEF);
    address internal sweeper = address(0x5EE9);
    address internal payoutRole = address(0x9A99);
    address internal user = address(0x1111);
    address internal outsider = address(0xDEAD);

    uint256 internal constant INITIAL_MINT = 1_000_000e6;

    function setUp() public {
        usdc = new MockToken("USD Coin", "USDC", 6, 0);
        xsgd = new MockToken("XSGD", "XSGD", 6, 0);
        weth = new MockToken("Wrapped Ether", "WETH", 18, 0);

        cctp = new MockCCTPMessenger(6); // arbitrary local domain
        stargateUsdc = new MockStargateRouter(address(usdc));

        SpokeVaultStable impl = new SpokeVaultStable();
        bytes memory init = abi.encodeCall(SpokeVaultStable.initialize, (owner));
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(impl),
            address(this),
            init
        );
        vault = SpokeVaultStable(address(proxy));

        vm.startPrank(owner);
        vault.setGateway(gateway);
        vault.setSweeper(sweeper);
        vault.setPayout(payoutRole);
        vault.setCctpMessenger(address(cctp));
        vault.setStargateRouter(address(usdc), address(stargateUsdc));
        vault.setAssetClassification(address(usdc), ISpokeVaultStable.AssetClassification.BRIDGED);
        vault.setAssetClassification(address(xsgd), ISpokeVaultStable.AssetClassification.SPOKE_NATIVE);
        vault.setAssetClassification(address(weth), ISpokeVaultStable.AssetClassification.BRIDGED);
        vm.stopPrank();

        // Pre-fund the gateway so it can forward tokens into the vault.
        usdc.mint(gateway, INITIAL_MINT);
        xsgd.mint(gateway, INITIAL_MINT);
        weth.mint(gateway, INITIAL_MINT);
    }

    // ============ Initialization ============

    function test_Initialize_SetsOwner() public view {
        assertEq(vault.owner(), owner);
    }

    function test_Initialize_RevertZeroOwner() public {
        SpokeVaultStable impl = new SpokeVaultStable();
        bytes memory badInit = abi.encodeCall(
            SpokeVaultStable.initialize,
            (address(0))
        );
        vm.expectRevert(ISpokeVaultStable.ZeroAddress.selector);
        new TransparentUpgradeableProxy(address(impl), address(this), badInit);
    }

    // ============ Asset registration ============

    function test_SetAssetClassification_OwnerOnly() public {
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(
                OwnableUpgradeable.OwnableUnauthorizedAccount.selector,
                outsider
            )
        );
        vault.setAssetClassification(
            address(usdc),
            ISpokeVaultStable.AssetClassification.BRIDGED
        );
    }

    function test_SetAssetClassification_RevertZeroAsset() public {
        vm.prank(owner);
        vm.expectRevert(ISpokeVaultStable.ZeroAddress.selector);
        vault.setAssetClassification(
            address(0),
            ISpokeVaultStable.AssetClassification.BRIDGED
        );
    }

    function test_SetAssetClassification_EmitsEvent() public {
        MockToken usdt = new MockToken("Tether", "USDT", 6, 0);
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit ISpokeVaultStable.AssetClassificationSet(
            address(usdt),
            ISpokeVaultStable.AssetClassification.BRIDGED
        );
        vault.setAssetClassification(
            address(usdt),
            ISpokeVaultStable.AssetClassification.BRIDGED
        );
        assertEq(
            uint8(vault.classificationOf(address(usdt))),
            uint8(ISpokeVaultStable.AssetClassification.BRIDGED)
        );
    }

    // ============ Role setters ============

    function test_RoleSetters_OwnerOnly() public {
        vm.startPrank(outsider);
        vm.expectRevert();
        vault.setGateway(gateway);
        vm.expectRevert();
        vault.setSweeper(sweeper);
        vm.expectRevert();
        vault.setPayout(payoutRole);
        vm.expectRevert();
        vault.setCctpMessenger(address(cctp));
        vm.expectRevert();
        vault.setStargateRouter(address(usdc), address(stargateUsdc));
        vm.stopPrank();
    }

    function test_RoleSetters_StoreValues() public view {
        assertEq(vault.gateway(), gateway);
        assertEq(vault.sweeper(), sweeper);
        assertEq(vault.payout(), payoutRole);
        assertEq(vault.cctpMessenger(), address(cctp));
        assertEq(vault.stargateRouterOf(address(usdc)), address(stargateUsdc));
    }

    // ============ depositBridged ============

    function test_DepositBridged_HappyPath() public {
        uint256 amount = 100e6;

        vm.startPrank(gateway);
        usdc.approve(address(vault), amount);
        vm.expectEmit(true, true, false, true);
        emit ISpokeVaultStable.BridgedDeposited(address(usdc), user, amount);
        vault.depositBridged(address(usdc), user, amount);
        vm.stopPrank();

        assertEq(vault.bridgedBalance(address(usdc)), amount);
        assertEq(usdc.balanceOf(address(vault)), amount);
    }

    function test_DepositBridged_OnlyGateway() public {
        vm.prank(outsider);
        vm.expectRevert(ISpokeVaultStable.Unauthorized.selector);
        vault.depositBridged(address(usdc), user, 1);
    }

    function test_DepositBridged_RevertSpokeNativeAsset() public {
        vm.startPrank(gateway);
        xsgd.approve(address(vault), 1);
        vm.expectRevert(ISpokeVaultStable.UnsupportedAsset.selector);
        vault.depositBridged(address(xsgd), user, 1);
        vm.stopPrank();
    }

    function test_DepositBridged_RevertZeros() public {
        vm.startPrank(gateway);
        vm.expectRevert(ISpokeVaultStable.ZeroAddress.selector);
        vault.depositBridged(address(0), user, 1);
        vm.expectRevert(ISpokeVaultStable.ZeroAddress.selector);
        vault.depositBridged(address(usdc), address(0), 1);
        vm.expectRevert(ISpokeVaultStable.ZeroAmount.selector);
        vault.depositBridged(address(usdc), user, 0);
        vm.stopPrank();
    }

    // ============ depositSpokeNative ============

    function test_DepositSpokeNative_HappyPath() public {
        uint256 amount = 50e6;
        vm.startPrank(gateway);
        xsgd.approve(address(vault), amount);
        vm.expectEmit(true, true, false, true);
        emit ISpokeVaultStable.SpokeNativeDeposited(address(xsgd), user, amount);
        vault.depositSpokeNative(address(xsgd), user, amount);
        vm.stopPrank();

        assertEq(vault.spokeNativeBalance(address(xsgd)), amount);
        assertEq(xsgd.balanceOf(address(vault)), amount);
    }

    function test_DepositSpokeNative_RevertBridgedAsset() public {
        vm.startPrank(gateway);
        usdc.approve(address(vault), 1);
        vm.expectRevert(ISpokeVaultStable.UnsupportedAsset.selector);
        vault.depositSpokeNative(address(usdc), user, 1);
        vm.stopPrank();
    }

    // ============ sweepCCTP ============

    function _seedBridged(address asset, uint256 amount) internal {
        vm.startPrank(gateway);
        MockToken(asset).approve(address(vault), amount);
        vault.depositBridged(asset, user, amount);
        vm.stopPrank();
    }

    function test_SweepCCTP_HappyPath() public {
        uint256 amount = 100e6;
        _seedBridged(address(usdc), amount);

        vm.prank(sweeper);
        (uint256 swept, uint64 nonce) = vault.sweepCCTP(
            address(usdc),
            3,
            bytes32(uint256(uint160(user)))
        );

        assertEq(swept, amount);
        assertEq(nonce, 1);
        assertEq(vault.bridgedBalance(address(usdc)), 0);
        assertEq(usdc.balanceOf(address(cctp)), amount);
        assertEq(cctp.burnCount(), 1);
    }

    function test_SweepCCTP_OnlySweeper() public {
        _seedBridged(address(usdc), 100e6);
        vm.prank(outsider);
        vm.expectRevert(ISpokeVaultStable.Unauthorized.selector);
        vault.sweepCCTP(address(usdc), 3, bytes32(uint256(uint160(user))));
    }

    function test_SweepCCTP_RevertSpokeNativeAsset() public {
        vm.prank(sweeper);
        vm.expectRevert(ISpokeVaultStable.CannotSweepSpokeNative.selector);
        vault.sweepCCTP(address(xsgd), 3, bytes32(uint256(uint160(user))));
    }

    function test_SweepCCTP_RevertZeroBalance() public {
        vm.prank(sweeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISpokeVaultStable.InsufficientBridgedBalance.selector,
                0,
                0
            )
        );
        vault.sweepCCTP(address(usdc), 3, bytes32(uint256(uint160(user))));
    }

    function test_SweepCCTP_RevertMessengerNotSet() public {
        vm.prank(owner);
        vault.setCctpMessenger(address(0));
        _seedBridged(address(usdc), 100e6);
        vm.prank(sweeper);
        vm.expectRevert(ISpokeVaultStable.CctpMessengerNotSet.selector);
        vault.sweepCCTP(address(usdc), 3, bytes32(uint256(uint160(user))));
    }

    function test_SweepCCTP_RevertUnsupportedAsset() public {
        MockToken stray = new MockToken("Stray", "STRAY", 18, 0);
        vm.prank(sweeper);
        vm.expectRevert(ISpokeVaultStable.UnsupportedAsset.selector);
        vault.sweepCCTP(address(stray), 3, bytes32(uint256(uint160(user))));
    }

    // ============ sweepStargate ============

    function test_SweepStargate_HappyPath() public {
        uint256 amount = 100e6;
        _seedBridged(address(usdc), amount);

        // Fund the sweeper for the native fee.
        vm.deal(sweeper, 1 ether);
        uint256 nativeFee = stargateUsdc.nativeFee();

        vm.prank(sweeper);
        (uint256 sent, uint256 received) = vault.sweepStargate{value: nativeFee}(
            address(usdc),
            30110, // arbitrary dst eid
            bytes32(uint256(uint160(user))),
            0,
            nativeFee
        );

        assertEq(sent, amount);
        // Mock applies a 6 bps pool fee.
        assertEq(received, (amount * (10_000 - 6)) / 10_000);
        assertEq(vault.bridgedBalance(address(usdc)), 0);
        assertEq(stargateUsdc.sendCount(), 1);
    }

    function test_SweepStargate_RevertInsufficientFee() public {
        _seedBridged(address(usdc), 100e6);
        vm.deal(sweeper, 1 ether);
        uint256 nativeFee = stargateUsdc.nativeFee();
        vm.prank(sweeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                SpokeVaultStable.InsufficientLzFee.selector,
                0,
                nativeFee
            )
        );
        vault.sweepStargate(
            address(usdc),
            30110,
            bytes32(uint256(uint160(user))),
            0,
            nativeFee
        );
    }

    function test_SweepStargate_RevertNoRouter() public {
        _seedBridged(address(weth), 1e6);
        vm.deal(sweeper, 1 ether);
        vm.prank(sweeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISpokeVaultStable.StargateRouterNotSet.selector,
                address(weth)
            )
        );
        vault.sweepStargate{value: 0.001 ether}(
            address(weth),
            30110,
            bytes32(uint256(uint160(user))),
            0,
            0.001 ether
        );
    }

    function test_SweepStargate_RevertSpokeNativeAsset() public {
        vm.prank(sweeper);
        vm.expectRevert(ISpokeVaultStable.CannotSweepSpokeNative.selector);
        vault.sweepStargate{value: 0}(
            address(xsgd),
            30110,
            bytes32(uint256(uint160(user))),
            0,
            0
        );
    }

    function test_SweepStargate_OnlySweeper() public {
        _seedBridged(address(usdc), 100e6);
        vm.deal(outsider, 1 ether);
        vm.prank(outsider);
        vm.expectRevert(ISpokeVaultStable.Unauthorized.selector);
        vault.sweepStargate{value: 0.001 ether}(
            address(usdc),
            30110,
            bytes32(uint256(uint160(user))),
            0,
            0.001 ether
        );
    }

    // ============ releaseSpokeNative ============

    function _seedSpokeNative(address asset, uint256 amount) internal {
        vm.startPrank(gateway);
        MockToken(asset).approve(address(vault), amount);
        vault.depositSpokeNative(asset, user, amount);
        vm.stopPrank();
    }

    function test_ReleaseSpokeNative_HappyPath() public {
        uint256 amount = 50e6;
        _seedSpokeNative(address(xsgd), amount);

        vm.prank(payoutRole);
        vm.expectEmit(true, true, false, true);
        emit ISpokeVaultStable.SpokeNativeReleased(address(xsgd), user, amount);
        vault.releaseSpokeNative(address(xsgd), user, amount);

        assertEq(vault.spokeNativeBalance(address(xsgd)), 0);
        assertEq(xsgd.balanceOf(user), amount);
    }

    function test_ReleaseSpokeNative_OnlyPayout() public {
        _seedSpokeNative(address(xsgd), 50e6);
        vm.prank(outsider);
        vm.expectRevert(ISpokeVaultStable.Unauthorized.selector);
        vault.releaseSpokeNative(address(xsgd), user, 1);
    }

    function test_ReleaseSpokeNative_RevertBridgedAsset() public {
        vm.prank(payoutRole);
        vm.expectRevert(ISpokeVaultStable.CannotReleaseBridged.selector);
        vault.releaseSpokeNative(address(usdc), user, 1);
    }

    function test_ReleaseSpokeNative_RevertInsufficient() public {
        _seedSpokeNative(address(xsgd), 10);
        vm.prank(payoutRole);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISpokeVaultStable.InsufficientSpokeNativeBalance.selector,
                10,
                100
            )
        );
        vault.releaseSpokeNative(address(xsgd), user, 100);
    }

    // ============ recallBridged ============

    function test_RecallBridged_HappyPath() public {
        uint256 amount = 100e6;
        _seedBridged(address(usdc), amount);

        vm.prank(gateway);
        vm.expectEmit(true, true, false, true);
        emit ISpokeVaultStable.BridgedRecalled(address(usdc), user, amount);
        vault.recallBridged(address(usdc), user, amount);

        assertEq(vault.bridgedBalance(address(usdc)), 0);
        assertEq(usdc.balanceOf(user), amount);
    }

    function test_RecallBridged_OnlyGateway() public {
        _seedBridged(address(usdc), 100e6);
        vm.prank(outsider);
        vm.expectRevert(ISpokeVaultStable.Unauthorized.selector);
        vault.recallBridged(address(usdc), user, 1);
    }

    function test_RecallBridged_RevertSpokeNativeAsset() public {
        vm.prank(gateway);
        vm.expectRevert(ISpokeVaultStable.UnsupportedAsset.selector);
        vault.recallBridged(address(xsgd), user, 1);
    }

    function test_RecallBridged_RevertInsufficient() public {
        _seedBridged(address(usdc), 10);
        vm.prank(gateway);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISpokeVaultStable.InsufficientBridgedBalance.selector,
                10,
                100
            )
        );
        vault.recallBridged(address(usdc), user, 100);
    }
}
