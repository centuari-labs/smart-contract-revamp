// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {BalanceLedger} from "../../src/core/balance-ledger/BalanceLedger.sol";
import {HubIntentSettler} from "../../src/core/cross-chain/HubIntentSettler.sol";
import {SettlementLedger} from "../../src/core/cross-chain/SettlementLedger.sol";
import {WithdrawalRegistry} from "../../src/core/cross-chain/WithdrawalRegistry.sol";
import {RiskModuleStub} from "../../src/core/risk/RiskModuleStub.sol";
import {HubDepositor} from "../../src/core/cross-chain/HubDepositor.sol";
import {IHubIntentSettler} from "../../src/interfaces/cross-chain/IHubIntentSettler.sol";
import {IWithdrawalRegistry} from "../../src/interfaces/cross-chain/IWithdrawalRegistry.sol";
import {MockToken} from "../../src/mocks/MockToken.sol";
import {MockLZEndpoint} from "../mocks/MockLZEndpoint.sol";

contract HubIntentSettlerConfirmDepositTest is Test {
    BalanceLedger internal ledger;
    HubIntentSettler internal settler;
    SettlementLedger internal settlementLedger;
    WithdrawalRegistry internal registry;
    RiskModuleStub internal riskModule;
    HubDepositor internal hubDepositor;
    MockToken internal usdc;
    MockToken internal xsgd;
    MockLZEndpoint internal spokeEndpoint;
    MockLZEndpoint internal hubEndpoint;

    address internal owner = address(0xA11CE);
    address internal operatorAddr = address(0x0BEE);
    address internal user = address(0x1111);
    address internal outsider = address(0xDEAD);
    address internal spokeGateway = address(0x5B0CE);

    uint32 internal constant SPOKE_EID = 30184; // Base
    uint32 internal constant HUB_EID = 30110; // Arbitrum
    uint256 internal constant BASE_CHAIN_ID = 8453;

    uint8 internal constant BRIDGED = 1;
    uint8 internal constant SPOKE_NATIVE = 2;

    function setUp() public {
        usdc = new MockToken("USD Coin", "USDC", 6, 0);
        xsgd = new MockToken("XSGD", "XSGD", 6, 0);

        spokeEndpoint = new MockLZEndpoint(SPOKE_EID);
        hubEndpoint = new MockLZEndpoint(HUB_EID);

        // Wire LZ endpoints for auto-delivery
        spokeEndpoint.setDestLzEndpoint(HUB_EID, address(hubEndpoint));

        // Deploy BalanceLedger
        BalanceLedger ledgerImpl = new BalanceLedger();
        bytes memory ledgerInit = abi.encodeCall(BalanceLedger.initialize, (owner, true));
        TransparentUpgradeableProxy ledgerProxy =
            new TransparentUpgradeableProxy(address(ledgerImpl), address(this), ledgerInit);
        ledger = BalanceLedger(address(ledgerProxy));

        // Deploy HubIntentSettler
        HubIntentSettler settlerImpl = new HubIntentSettler();
        bytes memory settlerInit = abi.encodeCall(HubIntentSettler.initialize, (owner, operatorAddr, address(ledger)));
        TransparentUpgradeableProxy settlerProxy =
            new TransparentUpgradeableProxy(address(settlerImpl), address(this), settlerInit);
        settler = HubIntentSettler(address(settlerProxy));

        // Deploy SettlementLedger (required by settler init)
        SettlementLedger slImpl = new SettlementLedger();
        bytes memory slInit = abi.encodeCall(SettlementLedger.initialize, (owner, operatorAddr, address(settler)));
        TransparentUpgradeableProxy slProxy = new TransparentUpgradeableProxy(address(slImpl), address(this), slInit);
        settlementLedger = SettlementLedger(address(slProxy));

        // Deploy RiskModuleStub + HubDepositor + WithdrawalRegistry
        riskModule = new RiskModuleStub(address(ledger));

        HubDepositor depImpl = new HubDepositor();
        bytes memory depInit = abi.encodeCall(HubDepositor.initialize, (owner, address(ledger)));
        TransparentUpgradeableProxy depProxy = new TransparentUpgradeableProxy(address(depImpl), address(this), depInit);
        hubDepositor = HubDepositor(address(depProxy));

        WithdrawalRegistry regImpl = new WithdrawalRegistry();
        bytes memory regInit = abi.encodeCall(
            WithdrawalRegistry.initialize,
            (owner, operatorAddr, address(ledger), address(riskModule), address(hubDepositor))
        );
        TransparentUpgradeableProxy regProxy = new TransparentUpgradeableProxy(address(regImpl), address(this), regInit);
        registry = WithdrawalRegistry(address(regProxy));

        // Wire everything
        vm.startPrank(owner);
        settler.setSettlementLedger(address(settlementLedger));
        settler.setLzEndpoint(address(hubEndpoint));
        settler.setTrustedRemote(SPOKE_EID, bytes32(uint256(uint160(spokeGateway))));
        settler.setWithdrawalRegistry(address(registry));
        ledger.forceAddWriter(address(settler));
        ledger.forceAddWriter(address(registry));
        registry.setHubIntentSettler(address(settler));
        registry.setSpokeNativeRoute(address(xsgd), BASE_CHAIN_ID, true);
        vm.stopPrank();
    }

    // ============ Helpers ============

    function _buildPayload(
        bytes32 depositId,
        address payloadUser,
        address asset,
        uint256 amount,
        uint8 classification,
        uint256 sourceChainId
    ) internal pure returns (bytes memory) {
        return abi.encode(depositId, payloadUser, asset, amount, classification, sourceChainId);
    }

    function _deliverFromSpoke(bytes32 depositId, address asset, uint256 amount, uint8 classification) internal {
        bytes memory payload = _buildPayload(depositId, user, asset, amount, classification, BASE_CHAIN_ID);
        // Simulate the hub endpoint calling `lzReceive` on the settler.
        HubIntentSettler.Origin memory origin =
            HubIntentSettler.Origin({srcEid: SPOKE_EID, sender: bytes32(uint256(uint160(spokeGateway))), nonce: 1});
        vm.prank(address(hubEndpoint));
        settler.lzReceive(origin, bytes32(0), payload, address(settler), bytes(""));
    }

    // ============ Happy path — BRIDGED ============

    function test_ConfirmDeposit_Bridged_CreditsLedger() public {
        bytes32 depositId = keccak256("bridged-deposit-1");
        uint256 amount = 100e6;

        _deliverFromSpoke(depositId, address(usdc), amount, BRIDGED);

        assertEq(ledger.available(user, address(usdc)), amount);
        assertEq(uint8(settler.depositStatus(depositId)), uint8(IHubIntentSettler.DepositStatus.CREDITED));
        // Chain liquidity unchanged for BRIDGED.
        assertEq(registry.chainLiquidity(address(usdc), BASE_CHAIN_ID), 0);
    }

    // ============ Happy path — SPOKE_NATIVE ============

    function test_ConfirmDeposit_SpokeNative_CreditsLedgerAndBumpsLiquidity() public {
        bytes32 depositId = keccak256("spoke-native-deposit-1");
        uint256 amount = 50e6;

        _deliverFromSpoke(depositId, address(xsgd), amount, SPOKE_NATIVE);

        assertEq(ledger.available(user, address(xsgd)), amount);
        assertEq(uint8(settler.depositStatus(depositId)), uint8(IHubIntentSettler.DepositStatus.CREDITED));
        assertEq(registry.chainLiquidity(address(xsgd), BASE_CHAIN_ID), amount);
    }

    function test_ConfirmDeposit_SpokeNative_MultipleDepositsAccumulate() public {
        _deliverFromSpoke(keccak256("sn-1"), address(xsgd), 50e6, SPOKE_NATIVE);

        // Second delivery with different depositId.
        HubIntentSettler.Origin memory origin =
            HubIntentSettler.Origin({srcEid: SPOKE_EID, sender: bytes32(uint256(uint160(spokeGateway))), nonce: 2});
        vm.prank(address(hubEndpoint));
        settler.lzReceive(
            origin,
            bytes32(0),
            _buildPayload(keccak256("sn-2"), user, address(xsgd), 30e6, SPOKE_NATIVE, BASE_CHAIN_ID),
            address(settler),
            bytes("")
        );

        assertEq(ledger.available(user, address(xsgd)), 80e6);
        assertEq(registry.chainLiquidity(address(xsgd), BASE_CHAIN_ID), 80e6);
    }

    // ============ Replay ============

    function test_ConfirmDeposit_RevertReplay() public {
        bytes32 depositId = keccak256("replay-test");
        _deliverFromSpoke(depositId, address(usdc), 100e6, BRIDGED);

        HubIntentSettler.Origin memory origin =
            HubIntentSettler.Origin({srcEid: SPOKE_EID, sender: bytes32(uint256(uint160(spokeGateway))), nonce: 2});
        vm.prank(address(hubEndpoint));
        vm.expectRevert(abi.encodeWithSelector(IHubIntentSettler.DepositAlreadyProcessed.selector, depositId));
        settler.lzReceive(
            origin,
            bytes32(0),
            _buildPayload(depositId, user, address(usdc), 100e6, BRIDGED, BASE_CHAIN_ID),
            address(settler),
            bytes("")
        );
    }

    // ============ Access control ============

    function test_ConfirmDeposit_RevertInvalidEndpoint() public {
        HubIntentSettler.Origin memory origin =
            HubIntentSettler.Origin({srcEid: SPOKE_EID, sender: bytes32(uint256(uint160(spokeGateway))), nonce: 1});

        vm.prank(outsider); // not the LZ endpoint
        vm.expectRevert(IHubIntentSettler.InvalidLzEndpoint.selector);
        settler.lzReceive(
            origin,
            bytes32(0),
            _buildPayload(keccak256("no-ep"), user, address(usdc), 100e6, BRIDGED, BASE_CHAIN_ID),
            address(settler),
            bytes("")
        );
    }

    function test_ConfirmDeposit_RevertUntrustedRemote() public {
        HubIntentSettler.Origin memory origin = HubIntentSettler.Origin({
            srcEid: SPOKE_EID,
            sender: bytes32(uint256(uint160(outsider))), // wrong peer
            nonce: 1
        });

        vm.prank(address(hubEndpoint));
        vm.expectRevert(
            abi.encodeWithSelector(
                IHubIntentSettler.UntrustedRemote.selector, SPOKE_EID, bytes32(uint256(uint160(outsider)))
            )
        );
        settler.lzReceive(
            origin,
            bytes32(0),
            _buildPayload(keccak256("untrusted"), user, address(usdc), 100e6, BRIDGED, BASE_CHAIN_ID),
            address(settler),
            bytes("")
        );
    }

    function test_ConfirmDeposit_RevertUnregisteredEid() public {
        uint32 unknownEid = 99999;
        HubIntentSettler.Origin memory origin =
            HubIntentSettler.Origin({srcEid: unknownEid, sender: bytes32(uint256(uint160(spokeGateway))), nonce: 1});

        vm.prank(address(hubEndpoint));
        vm.expectRevert(
            abi.encodeWithSelector(
                IHubIntentSettler.UntrustedRemote.selector, unknownEid, bytes32(uint256(uint160(spokeGateway)))
            )
        );
        settler.lzReceive(
            origin,
            bytes32(0),
            _buildPayload(keccak256("unknown-eid"), user, address(usdc), 100e6, BRIDGED, BASE_CHAIN_ID),
            address(settler),
            bytes("")
        );
    }

    // ============ Paused ============

    function test_ConfirmDeposit_RevertWhenPaused() public {
        vm.prank(owner);
        settler.pause();

        HubIntentSettler.Origin memory origin =
            HubIntentSettler.Origin({srcEid: SPOKE_EID, sender: bytes32(uint256(uint160(spokeGateway))), nonce: 1});

        vm.prank(address(hubEndpoint));
        vm.expectRevert(IHubIntentSettler.ContractPaused.selector);
        settler.lzReceive(
            origin,
            bytes32(0),
            _buildPayload(keccak256("paused"), user, address(usdc), 100e6, BRIDGED, BASE_CHAIN_ID),
            address(settler),
            bytes("")
        );
    }

    // ============ Admin ============

    function test_SetLzEndpoint_OwnerOnly() public {
        vm.prank(outsider);
        vm.expectRevert();
        settler.setLzEndpoint(address(hubEndpoint));
    }

    function test_SetLzEndpoint_RevertZero() public {
        vm.prank(owner);
        vm.expectRevert(IHubIntentSettler.ZeroAddress.selector);
        settler.setLzEndpoint(address(0));
    }

    function test_SetTrustedRemote_OwnerOnly() public {
        vm.prank(outsider);
        vm.expectRevert();
        settler.setTrustedRemote(SPOKE_EID, bytes32(0));
    }

    function test_SetWithdrawalRegistry_OwnerOnly() public {
        vm.prank(outsider);
        vm.expectRevert();
        settler.setWithdrawalRegistry(address(registry));
    }

    function test_Views_ReturnCorrectValues() public view {
        assertEq(settler.lzEndpoint(), address(hubEndpoint));
        assertEq(settler.trustedRemote(SPOKE_EID), bytes32(uint256(uint160(spokeGateway))));
        assertEq(settler.withdrawalRegistry(), address(registry));
    }
}
