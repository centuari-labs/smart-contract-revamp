// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, Vm} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {BalanceLedger} from "../../src/core/balance-ledger/BalanceLedger.sol";
import {HubDepositor} from "../../src/core/cross-chain/HubDepositor.sol";
import {WithdrawalRegistry} from "../../src/core/cross-chain/WithdrawalRegistry.sol";
import {RiskModuleStub} from "../../src/core/risk/RiskModuleStub.sol";
import {IWithdrawalRegistry} from "../../src/interfaces/cross-chain/IWithdrawalRegistry.sol";
import {MockToken} from "../../src/mocks/MockToken.sol";
import {MockLZEndpoint} from "../mocks/MockLZEndpoint.sol";

contract WithdrawalRegistryTest is Test {
    BalanceLedger internal ledger;
    HubDepositor internal depositor;
    WithdrawalRegistry internal registry;
    RiskModuleStub internal riskModule;
    MockToken internal usdc;

    address internal owner = address(0xA11CE);
    address internal operator = address(0x0BEE);
    address internal user = address(0x1111);
    address internal outsider = address(0xDEAD);

    uint256 internal constant INITIAL_MINT = 1_000_000e6;
    uint256 internal constant DEPOSIT_AMOUNT = 100_000e6;

    function setUp() public {
        usdc = new MockToken("USD Coin", "USDC", 6, 0);

        // Deploy BalanceLedger behind proxy
        BalanceLedger ledgerImpl = new BalanceLedger();
        bytes memory ledgerInit = abi.encodeCall(BalanceLedger.initialize, (owner, true));
        TransparentUpgradeableProxy ledgerProxy =
            new TransparentUpgradeableProxy(address(ledgerImpl), address(this), ledgerInit);
        ledger = BalanceLedger(address(ledgerProxy));

        // Deploy HubDepositor behind proxy
        HubDepositor depositorImpl = new HubDepositor();
        bytes memory depositorInit = abi.encodeCall(HubDepositor.initialize, (owner, address(ledger)));
        TransparentUpgradeableProxy depositorProxy =
            new TransparentUpgradeableProxy(address(depositorImpl), address(this), depositorInit);
        depositor = HubDepositor(address(depositorProxy));

        // Deploy RiskModuleStub (not upgradeable)
        riskModule = new RiskModuleStub(address(ledger));

        // Deploy WithdrawalRegistry behind proxy
        WithdrawalRegistry registryImpl = new WithdrawalRegistry();
        bytes memory registryInit = abi.encodeCall(
            WithdrawalRegistry.initialize, (owner, operator, address(ledger), address(riskModule), address(depositor))
        );
        TransparentUpgradeableProxy registryProxy =
            new TransparentUpgradeableProxy(address(registryImpl), address(this), registryInit);
        registry = WithdrawalRegistry(address(registryProxy));

        // Wire: register HubDepositor + WithdrawalRegistry as BalanceLedger writers
        vm.startPrank(owner);
        ledger.forceAddWriter(address(depositor));
        ledger.forceAddWriter(address(registry));
        // Whitelist USDC on HubDepositor
        depositor.addSupportedAsset(address(usdc));
        // Authorize WithdrawalRegistry to call payoutDirect on HubDepositor
        depositor.setAuthorizedCaller(address(registry), true);
        vm.stopPrank();

        // Wire LZ payout dispatch (needed for cross-chain authorize tests).
        MockLZEndpoint lz = new MockLZEndpoint(30110);
        vm.startPrank(owner);
        registry.setPayoutEndpoint(address(lz));
        registry.setSpokeEid(8453, 30184); // Base chain → Base eid
        registry.setPayoutPeer(30184, bytes32(uint256(uint160(address(0xFACE)))));
        vm.stopPrank();
        vm.deal(operator, 10 ether); // Fund operator for LZ fees

        // Seed user: mint tokens, deposit via HubDepositor
        usdc.mint(user, INITIAL_MINT);
        vm.startPrank(user);
        usdc.approve(address(depositor), DEPOSIT_AMOUNT);
        depositor.deposit(address(usdc), DEPOSIT_AMOUNT);
        vm.stopPrank();
    }

    // ============ Helpers ============

    function _requestWithdrawal(uint256 amount, uint256 targetChainId) internal returns (bytes32) {
        vm.prank(user);
        return registry.requestWithdrawal(address(usdc), amount, targetChainId);
    }

    function _requestHubNative(uint256 amount) internal returns (bytes32) {
        return _requestWithdrawal(amount, block.chainid);
    }

    function _requestCrossChain(uint256 amount) internal returns (bytes32) {
        return _requestWithdrawal(amount, 8453); // Base chain ID
    }

    // ============ Initialization ============

    function test_Initialize_SetsState() public view {
        assertEq(registry.owner(), owner);
        assertEq(registry.operator(), operator);
        assertEq(registry.balanceLedger(), address(ledger));
        assertEq(registry.riskModule(), address(riskModule));
        assertEq(registry.hubDepositor(), address(depositor));
        assertFalse(registry.paused());
    }

    function test_Initialize_RevertZeroOwner() public {
        WithdrawalRegistry impl = new WithdrawalRegistry();
        bytes memory badInit = abi.encodeCall(
            WithdrawalRegistry.initialize,
            (address(0), operator, address(ledger), address(riskModule), address(depositor))
        );
        vm.expectRevert(IWithdrawalRegistry.ZeroAddress.selector);
        new TransparentUpgradeableProxy(address(impl), address(this), badInit);
    }

    function test_Initialize_RevertZeroOperator() public {
        WithdrawalRegistry impl = new WithdrawalRegistry();
        bytes memory badInit = abi.encodeCall(
            WithdrawalRegistry.initialize, (owner, address(0), address(ledger), address(riskModule), address(depositor))
        );
        vm.expectRevert(IWithdrawalRegistry.ZeroAddress.selector);
        new TransparentUpgradeableProxy(address(impl), address(this), badInit);
    }

    function test_Initialize_RevertZeroBalanceLedger() public {
        WithdrawalRegistry impl = new WithdrawalRegistry();
        bytes memory badInit = abi.encodeCall(
            WithdrawalRegistry.initialize, (owner, operator, address(0), address(riskModule), address(depositor))
        );
        vm.expectRevert(IWithdrawalRegistry.ZeroAddress.selector);
        new TransparentUpgradeableProxy(address(impl), address(this), badInit);
    }

    function test_Initialize_RevertZeroRiskModule() public {
        WithdrawalRegistry impl = new WithdrawalRegistry();
        bytes memory badInit = abi.encodeCall(
            WithdrawalRegistry.initialize, (owner, operator, address(ledger), address(0), address(depositor))
        );
        vm.expectRevert(IWithdrawalRegistry.ZeroAddress.selector);
        new TransparentUpgradeableProxy(address(impl), address(this), badInit);
    }

    function test_Initialize_RevertZeroHubDepositor() public {
        WithdrawalRegistry impl = new WithdrawalRegistry();
        bytes memory badInit = abi.encodeCall(
            WithdrawalRegistry.initialize, (owner, operator, address(ledger), address(riskModule), address(0))
        );
        vm.expectRevert(IWithdrawalRegistry.ZeroAddress.selector);
        new TransparentUpgradeableProxy(address(impl), address(this), badInit);
    }

    // ============ requestWithdrawal ============

    function test_RequestWithdrawal_CreatesRequest() public {
        uint256 amount = 1000e6;
        bytes32 requestId = _requestHubNative(amount);

        IWithdrawalRegistry.WithdrawalRequest memory req = registry.getRequest(requestId);
        assertEq(req.user, user);
        assertEq(req.asset, address(usdc));
        assertEq(req.amount, amount);
        assertEq(req.targetChainId, block.chainid);
        assertEq(uint8(req.status), uint8(IWithdrawalRegistry.WithdrawalStatus.PENDING));
        assertEq(req.createdAt, uint64(block.timestamp));
        assertEq(req.updatedAt, uint64(block.timestamp));
    }

    function test_RequestWithdrawal_DebitsLedger() public {
        uint256 amount = 1000e6;
        uint256 balanceBefore = ledger.available(user, address(usdc));

        _requestHubNative(amount);

        assertEq(ledger.available(user, address(usdc)), balanceBefore - amount);
    }

    function test_RequestWithdrawal_EmitsEvent() public {
        uint256 amount = 1000e6;

        vm.recordLogs();
        vm.prank(user);
        bytes32 requestId = registry.requestWithdrawal(address(usdc), amount, block.chainid);

        Vm.Log[] memory entries = vm.getRecordedLogs();
        bool found = false;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == IWithdrawalRegistry.WithdrawalRequested.selector) {
                assertEq(entries[i].topics[1], requestId);
                assertEq(entries[i].topics[2], bytes32(uint256(uint160(user))));
                assertEq(entries[i].topics[3], bytes32(uint256(uint160(address(usdc)))));
                found = true;
                break;
            }
        }
        assertTrue(found, "WithdrawalRequested event not emitted");
    }

    function test_RequestWithdrawal_RevertZeroAsset() public {
        vm.prank(user);
        vm.expectRevert(IWithdrawalRegistry.ZeroAddress.selector);
        registry.requestWithdrawal(address(0), 1000e6, block.chainid);
    }

    function test_RequestWithdrawal_RevertZeroAmount() public {
        vm.prank(user);
        vm.expectRevert(IWithdrawalRegistry.ZeroAmount.selector);
        registry.requestWithdrawal(address(usdc), 0, block.chainid);
    }

    function test_RequestWithdrawal_RevertInsufficientBalance() public {
        vm.prank(user);
        vm.expectRevert(); // BalanceLedger InsufficientBalance
        registry.requestWithdrawal(address(usdc), DEPOSIT_AMOUNT + 1, block.chainid);
    }

    function test_RequestWithdrawal_RevertWhenPaused() public {
        vm.prank(owner);
        registry.pause();

        vm.prank(user);
        vm.expectRevert(IWithdrawalRegistry.ContractPaused.selector);
        registry.requestWithdrawal(address(usdc), 1000e6, block.chainid);
    }

    function test_RequestWithdrawal_RevertBlockedByHF() public {
        // Flag USDC as collateral for user → RiskModuleStub will reject
        vm.prank(owner);
        ledger.forceAddWriter(address(this));
        ledger.markCollateral(user, address(usdc));

        vm.prank(user);
        vm.expectRevert(IWithdrawalRegistry.WithdrawalBlockedByHF.selector);
        registry.requestWithdrawal(address(usdc), 1000e6, block.chainid);
    }

    function test_RequestWithdrawal_UniqueRequestIds() public {
        bytes32 id1 = _requestHubNative(1000e6);
        bytes32 id2 = _requestHubNative(1000e6);

        assertTrue(id1 != id2);
    }

    // ============ authorize (hub-native) ============

    function test_Authorize_HubNative_CompletesDirectly() public {
        uint256 amount = 1000e6;
        bytes32 requestId = _requestHubNative(amount);

        vm.prank(operator);
        registry.authorize(requestId);

        IWithdrawalRegistry.WithdrawalRequest memory req = registry.getRequest(requestId);
        assertEq(uint8(req.status), uint8(IWithdrawalRegistry.WithdrawalStatus.COMPLETED));
    }

    function test_Authorize_HubNative_TransfersTokensToUser() public {
        uint256 amount = 1000e6;
        uint256 userTokensBefore = usdc.balanceOf(user);
        bytes32 requestId = _requestHubNative(amount);

        vm.prank(operator);
        registry.authorize(requestId);

        assertEq(usdc.balanceOf(user), userTokensBefore + amount);
    }

    function test_Authorize_HubNative_EmitsEvents() public {
        uint256 amount = 1000e6;
        bytes32 requestId = _requestHubNative(amount);

        vm.prank(operator);
        vm.expectEmit(true, false, false, false);
        emit IWithdrawalRegistry.WithdrawalAuthorized(requestId);
        vm.expectEmit(true, false, false, false);
        emit IWithdrawalRegistry.WithdrawalCompleted(requestId);
        registry.authorize(requestId);
    }

    // ============ authorize (cross-chain) ============

    function test_Authorize_CrossChain_SetsProcessing() public {
        uint256 amount = 1000e6;
        bytes32 requestId = _requestCrossChain(amount);

        vm.prank(operator);
        registry.authorize{value: 0.001 ether}(requestId);

        IWithdrawalRegistry.WithdrawalRequest memory req = registry.getRequest(requestId);
        assertEq(uint8(req.status), uint8(IWithdrawalRegistry.WithdrawalStatus.PROCESSING));
    }

    function test_Authorize_CrossChain_EmitsAuthorizedOnly() public {
        uint256 amount = 1000e6;
        bytes32 requestId = _requestCrossChain(amount);

        vm.prank(operator);
        vm.expectEmit(true, false, false, false);
        emit IWithdrawalRegistry.WithdrawalAuthorized(requestId);
        registry.authorize{value: 0.001 ether}(requestId);
    }

    // ============ authorize access control ============

    function test_Authorize_RevertNonOperator() public {
        bytes32 requestId = _requestHubNative(1000e6);

        vm.prank(outsider);
        vm.expectRevert(IWithdrawalRegistry.Unauthorized.selector);
        registry.authorize(requestId);
    }

    function test_Authorize_RevertInvalidRequestId() public {
        vm.prank(operator);
        vm.expectRevert(IWithdrawalRegistry.InvalidRequestId.selector);
        registry.authorize(bytes32(uint256(999)));
    }

    function test_Authorize_RevertNotPending() public {
        bytes32 requestId = _requestCrossChain(1000e6);

        // Authorize → PROCESSING
        vm.prank(operator);
        registry.authorize{value: 0.001 ether}(requestId);

        // Try to authorize again → should revert
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IWithdrawalRegistry.InvalidStatusTransition.selector,
                IWithdrawalRegistry.WithdrawalStatus.PROCESSING,
                IWithdrawalRegistry.WithdrawalStatus.PROCESSING
            )
        );
        registry.authorize{value: 0.001 ether}(requestId);
    }

    function test_Authorize_RevertWhenPaused() public {
        bytes32 requestId = _requestHubNative(1000e6);

        vm.prank(owner);
        registry.pause();

        vm.prank(operator);
        vm.expectRevert(IWithdrawalRegistry.ContractPaused.selector);
        registry.authorize(requestId);
    }

    // ============ markCompleted ============

    function test_MarkCompleted_FromProcessing() public {
        bytes32 requestId = _requestCrossChain(1000e6);

        vm.prank(operator);
        registry.authorize{value: 0.001 ether}(requestId); // → PROCESSING

        vm.prank(operator);
        registry.markCompleted(requestId);

        IWithdrawalRegistry.WithdrawalRequest memory req = registry.getRequest(requestId);
        assertEq(uint8(req.status), uint8(IWithdrawalRegistry.WithdrawalStatus.COMPLETED));
    }

    function test_MarkCompleted_EmitsEvent() public {
        bytes32 requestId = _requestCrossChain(1000e6);

        vm.prank(operator);
        registry.authorize{value: 0.001 ether}(requestId);

        vm.prank(operator);
        vm.expectEmit(true, false, false, false);
        emit IWithdrawalRegistry.WithdrawalCompleted(requestId);
        registry.markCompleted(requestId);
    }

    function test_MarkCompleted_RevertFromPending() public {
        bytes32 requestId = _requestHubNative(1000e6);

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IWithdrawalRegistry.InvalidStatusTransition.selector,
                IWithdrawalRegistry.WithdrawalStatus.PENDING,
                IWithdrawalRegistry.WithdrawalStatus.COMPLETED
            )
        );
        registry.markCompleted(requestId);
    }

    function test_MarkCompleted_RevertNonOperator() public {
        bytes32 requestId = _requestCrossChain(1000e6);

        vm.prank(operator);
        registry.authorize{value: 0.001 ether}(requestId);

        vm.prank(outsider);
        vm.expectRevert(IWithdrawalRegistry.Unauthorized.selector);
        registry.markCompleted(requestId);
    }

    // ============ markFailed ============

    function test_MarkFailed_FromPending_RefundsUser() public {
        uint256 amount = 1000e6;
        uint256 balanceBefore = ledger.available(user, address(usdc));
        bytes32 requestId = _requestHubNative(amount);

        // Balance should be debited after request
        assertEq(ledger.available(user, address(usdc)), balanceBefore - amount);

        vm.prank(operator);
        registry.markFailed(requestId);

        // Balance should be refunded
        assertEq(ledger.available(user, address(usdc)), balanceBefore);

        IWithdrawalRegistry.WithdrawalRequest memory req = registry.getRequest(requestId);
        assertEq(uint8(req.status), uint8(IWithdrawalRegistry.WithdrawalStatus.FAILED));
    }

    function test_MarkFailed_FromProcessing_RefundsUser() public {
        uint256 amount = 1000e6;
        uint256 balanceBefore = ledger.available(user, address(usdc));
        bytes32 requestId = _requestCrossChain(amount);

        vm.prank(operator);
        registry.authorize{value: 0.001 ether}(requestId); // → PROCESSING

        vm.prank(operator);
        registry.markFailed(requestId);

        assertEq(ledger.available(user, address(usdc)), balanceBefore);

        IWithdrawalRegistry.WithdrawalRequest memory req = registry.getRequest(requestId);
        assertEq(uint8(req.status), uint8(IWithdrawalRegistry.WithdrawalStatus.FAILED));
    }

    function test_MarkFailed_EmitsEvent() public {
        bytes32 requestId = _requestHubNative(1000e6);

        vm.prank(operator);
        vm.expectEmit(true, false, false, false);
        emit IWithdrawalRegistry.WithdrawalFailed(requestId);
        registry.markFailed(requestId);
    }

    function test_MarkFailed_RevertFromCompleted() public {
        bytes32 requestId = _requestHubNative(1000e6);

        vm.prank(operator);
        registry.authorize(requestId); // Hub-native → COMPLETED

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IWithdrawalRegistry.InvalidStatusTransition.selector,
                IWithdrawalRegistry.WithdrawalStatus.COMPLETED,
                IWithdrawalRegistry.WithdrawalStatus.FAILED
            )
        );
        registry.markFailed(requestId);
    }

    function test_MarkFailed_RevertFromFailed() public {
        bytes32 requestId = _requestHubNative(1000e6);

        vm.prank(operator);
        registry.markFailed(requestId);

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IWithdrawalRegistry.InvalidStatusTransition.selector,
                IWithdrawalRegistry.WithdrawalStatus.FAILED,
                IWithdrawalRegistry.WithdrawalStatus.FAILED
            )
        );
        registry.markFailed(requestId);
    }

    function test_MarkFailed_RevertNonOperator() public {
        bytes32 requestId = _requestHubNative(1000e6);

        vm.prank(outsider);
        vm.expectRevert(IWithdrawalRegistry.Unauthorized.selector);
        registry.markFailed(requestId);
    }

    // ============ Terminal state transitions ============

    function test_CannotTransitionFromCompleted() public {
        bytes32 requestId = _requestHubNative(1000e6);

        vm.prank(operator);
        registry.authorize(requestId); // Hub-native → COMPLETED

        // Cannot markCompleted from COMPLETED
        vm.prank(operator);
        vm.expectRevert();
        registry.markCompleted(requestId);

        // Cannot markFailed from COMPLETED
        vm.prank(operator);
        vm.expectRevert();
        registry.markFailed(requestId);
    }

    // ============ Governance ============

    function test_SetOperator() public {
        address newOperator = address(0xBEEF);

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit IWithdrawalRegistry.OperatorUpdated(operator, newOperator);
        registry.setOperator(newOperator);

        assertEq(registry.operator(), newOperator);
    }

    function test_SetOperator_RevertZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(IWithdrawalRegistry.ZeroAddress.selector);
        registry.setOperator(address(0));
    }

    function test_SetOperator_RevertNonOwner() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, outsider));
        registry.setOperator(address(0xBEEF));
    }

    function test_SetRiskModule() public {
        address newRiskModule = address(0xBEEF);

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit IWithdrawalRegistry.RiskModuleUpdated(address(riskModule), newRiskModule);
        registry.setRiskModule(newRiskModule);

        assertEq(registry.riskModule(), newRiskModule);
    }

    function test_SetRiskModule_RevertZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(IWithdrawalRegistry.ZeroAddress.selector);
        registry.setRiskModule(address(0));
    }

    function test_SetHubDepositor() public {
        address newHubDepositor = address(0xBEEF);

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit IWithdrawalRegistry.HubDepositorUpdated(address(depositor), newHubDepositor);
        registry.setHubDepositor(newHubDepositor);

        assertEq(registry.hubDepositor(), newHubDepositor);
    }

    function test_SetHubDepositor_RevertZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(IWithdrawalRegistry.ZeroAddress.selector);
        registry.setHubDepositor(address(0));
    }

    function test_Pause_Unpause() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit IWithdrawalRegistry.Paused(owner);
        registry.pause();
        assertTrue(registry.paused());

        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit IWithdrawalRegistry.Unpaused(owner);
        registry.unpause();
        assertFalse(registry.paused());
    }

    function test_Pause_RevertNonOwner() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, outsider));
        registry.pause();
    }

    // ============ Fuzz ============

    function testFuzz_RequestAndAuthorizeHubNative(uint256 amount) public {
        amount = bound(amount, 1, DEPOSIT_AMOUNT);

        uint256 userTokensBefore = usdc.balanceOf(user);
        bytes32 requestId = _requestHubNative(amount);

        vm.prank(operator);
        registry.authorize(requestId);

        // User should get tokens back
        assertEq(usdc.balanceOf(user), userTokensBefore + amount);
        // Ledger should be debited
        assertEq(ledger.available(user, address(usdc)), DEPOSIT_AMOUNT - amount);
    }
}
