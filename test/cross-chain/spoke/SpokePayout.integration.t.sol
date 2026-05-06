// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

// Spoke contracts
import {SpokeDepositGateway} from "../../../src/core/cross-chain/spoke/SpokeDepositGateway.sol";
import {SpokeVaultStable} from "../../../src/core/cross-chain/spoke/SpokeVaultStable.sol";
import {SpokePayout} from "../../../src/core/cross-chain/spoke/SpokePayout.sol";
import {ISpokeVaultStable} from "../../../src/interfaces/cross-chain/spoke/ISpokeVaultStable.sol";

// Hub contracts
import {BalanceLedger} from "../../../src/core/balance-ledger/BalanceLedger.sol";
import {HubDepositor} from "../../../src/core/cross-chain/HubDepositor.sol";
import {HubIntentSettler} from "../../../src/core/cross-chain/HubIntentSettler.sol";
import {IHubIntentSettler} from "../../../src/interfaces/cross-chain/IHubIntentSettler.sol";
import {SettlementLedger} from "../../../src/core/cross-chain/SettlementLedger.sol";
import {WithdrawalRegistry} from "../../../src/core/cross-chain/WithdrawalRegistry.sol";
import {RiskModuleStub} from "../../../src/core/risk/RiskModuleStub.sol";

import {MockToken} from "../../../src/mocks/MockToken.sol";
import {MockLZEndpoint} from "../../mocks/MockLZEndpoint.sol";

/// @title SpokePayout Integration Test
/// @notice Full round-trip: spoke deposit → hub credit → hub withdrawal →
///         spoke payout, all in a single-chain forge test using
///         MockLZEndpoint auto-delivery.
contract SpokePayoutIntegrationTest is Test {
    // ---- Spoke ----
    SpokeVaultStable internal vault;
    SpokeDepositGateway internal gateway;
    SpokePayout internal spokePayout;
    MockLZEndpoint internal spokeEndpoint;

    // ---- Hub ----
    BalanceLedger internal ledger;
    HubDepositor internal hubDepositor;
    HubIntentSettler internal settler;
    SettlementLedger internal settlementLedger;
    WithdrawalRegistry internal registry;
    RiskModuleStub internal riskModule;
    MockLZEndpoint internal hubEndpoint;

    MockToken internal xsgd; // SPOKE_NATIVE

    address internal owner = address(0xA11CE);
    address internal operatorAddr = address(0x0BEE);
    address internal sweeperAddr = address(0x5EE9);
    address internal user = address(0x1111);

    uint32 internal constant SPOKE_EID = 30184;
    uint32 internal constant HUB_EID = 30110;
    uint256 internal constant BASE_CHAIN_ID = 8453;
    uint256 internal constant DEPOSIT = 100e6;

    function setUp() public {
        xsgd = new MockToken("XSGD", "XSGD", 6, 0);

        // ---- Deploy LZ endpoints ----
        spokeEndpoint = new MockLZEndpoint(SPOKE_EID);
        hubEndpoint = new MockLZEndpoint(HUB_EID);

        // ---- Deploy hub contracts ----
        ledger =
            BalanceLedger(_proxy(address(new BalanceLedger()), abi.encodeCall(BalanceLedger.initialize, (owner, true))));

        hubDepositor = HubDepositor(
            _proxy(address(new HubDepositor()), abi.encodeCall(HubDepositor.initialize, (owner, address(ledger))))
        );

        riskModule = new RiskModuleStub(address(ledger));

        settler = HubIntentSettler(
            _proxy(
                address(new HubIntentSettler()),
                abi.encodeCall(HubIntentSettler.initialize, (owner, operatorAddr, address(ledger)))
            )
        );

        settlementLedger = SettlementLedger(
            _proxy(
                address(new SettlementLedger()),
                abi.encodeCall(SettlementLedger.initialize, (owner, operatorAddr, address(settler)))
            )
        );

        registry = WithdrawalRegistry(
            _proxy(
                address(new WithdrawalRegistry()),
                abi.encodeCall(
                    WithdrawalRegistry.initialize,
                    (owner, operatorAddr, address(ledger), address(riskModule), address(hubDepositor))
                )
            )
        );

        // ---- Deploy spoke contracts ----
        vault = SpokeVaultStable(
            _proxy(address(new SpokeVaultStable()), abi.encodeCall(SpokeVaultStable.initialize, (owner)))
        );

        gateway = SpokeDepositGateway(
            _proxy(
                address(new SpokeDepositGateway()),
                abi.encodeCall(SpokeDepositGateway.initialize, (owner, address(vault), address(spokeEndpoint), HUB_EID))
            )
        );

        spokePayout = SpokePayout(
            _proxy(
                address(new SpokePayout()),
                abi.encodeCall(SpokePayout.initialize, (owner, address(vault), address(spokeEndpoint)))
            )
        );

        // ---- Wire everything ----
        vm.startPrank(owner);
        // Hub wiring
        settler.setSettlementLedger(address(settlementLedger));
        settler.setLzEndpoint(address(hubEndpoint));
        settler.setTrustedRemote(SPOKE_EID, bytes32(uint256(uint160(address(gateway)))));
        settler.setWithdrawalRegistry(address(registry));

        ledger.forceAddWriter(address(settler));
        ledger.forceAddWriter(address(registry));
        ledger.forceAddWriter(address(hubDepositor));

        hubDepositor.addSupportedAsset(address(xsgd));
        hubDepositor.setAuthorizedCaller(address(registry), true);

        registry.setHubIntentSettler(address(settler));
        registry.setSpokeNativeRoute(address(xsgd), BASE_CHAIN_ID, true);
        registry.setPayoutEndpoint(address(hubEndpoint));
        registry.setSpokeEid(BASE_CHAIN_ID, SPOKE_EID);
        registry.setPayoutPeer(SPOKE_EID, bytes32(uint256(uint160(address(spokePayout)))));

        // Spoke wiring
        vault.setGateway(address(gateway));
        vault.setPayout(address(spokePayout));
        vault.setSweeper(sweeperAddr);
        vault.setAssetClassification(address(xsgd), ISpokeVaultStable.AssetClassification.SPOKE_NATIVE);

        gateway.setAssetClassification(address(xsgd), ISpokeVaultStable.AssetClassification.SPOKE_NATIVE);
        gateway.setPeer(HUB_EID, bytes32(uint256(uint160(address(settler)))));

        spokePayout.setSweeper(sweeperAddr);
        spokePayout.setPeer(HUB_EID, bytes32(uint256(uint160(address(registry)))));
        vm.stopPrank();

        // ---- LZ endpoint cross-wiring for auto-delivery ----
        // spoke → hub: gateway sends, hubEndpoint receives for settler
        spokeEndpoint.setDestLzEndpoint(HUB_EID, address(hubEndpoint));
        spokeEndpoint.setAutoDeliver(true);

        // hub → spoke: registry sends, spokeEndpoint receives for payout
        hubEndpoint.setDestLzEndpoint(SPOKE_EID, address(spokeEndpoint));
        hubEndpoint.setAutoDeliver(true);

        // ---- Fund user ----
        xsgd.mint(user, 1_000_000e6);
        vm.deal(user, 100 ether);
        vm.deal(operatorAddr, 100 ether);
    }

    function _proxy(address impl, bytes memory init) internal returns (address) {
        return address(new TransparentUpgradeableProxy(impl, address(this), init));
    }

    // ============ Full round-trip: SPOKE_NATIVE deposit → credit → withdraw → payout ============

    function test_FullRoundTrip_SpokeNative() public {
        uint256 userXsgdBefore = xsgd.balanceOf(user);

        // Step 1: User deposits XSGD on spoke.
        // Simulate the spoke running on Base so that block.chainid in the
        // payload matches the BASE_CHAIN_ID used for chain-liquidity config.
        vm.chainId(BASE_CHAIN_ID);
        vm.startPrank(user);
        xsgd.approve(address(gateway), DEPOSIT);
        bytes32 depositId = gateway.deposit{value: 0.001 ether}(address(xsgd), DEPOSIT);
        vm.stopPrank();
        vm.chainId(31337); // revert to default for hub assertions

        // Verify: hub BalanceLedger credited via auto-delivery.
        assertEq(ledger.available(user, address(xsgd)), DEPOSIT);
        // Verify: chain liquidity bumped.
        assertEq(registry.chainLiquidity(address(xsgd), BASE_CHAIN_ID), DEPOSIT);
        // Verify: deposit marked CREDITED.
        assertEq(uint8(settler.depositStatus(depositId)), uint8(IHubIntentSettler.DepositStatus.CREDITED));

        // Step 2: User requests withdrawal back to Base.
        vm.prank(user);
        bytes32 requestId = registry.requestWithdrawal(address(xsgd), DEPOSIT, BASE_CHAIN_ID);

        // Verify: ledger debited.
        assertEq(ledger.available(user, address(xsgd)), 0);
        // Verify: chain liquidity decremented.
        assertEq(registry.chainLiquidity(address(xsgd), BASE_CHAIN_ID), 0);

        // Step 3: Operator authorizes → LZ dispatches payout to spoke
        //         → SpokePayout.lzReceive → vault.releaseSpokeNative → user gets XSGD.
        vm.prank(operatorAddr);
        registry.authorize{value: 0.001 ether}(requestId);

        // Verify: user received tokens back on spoke.
        assertEq(xsgd.balanceOf(user), userXsgdBefore);
        // Verify: vault spoke-native custody decremented.
        assertEq(vault.spokeNativeBalance(address(xsgd)), 0);
    }
}
