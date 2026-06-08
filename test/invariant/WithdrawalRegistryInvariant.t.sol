// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {BalanceLedger} from "../../src/core/balance-ledger/BalanceLedger.sol";
import {HubDepositor} from "../../src/core/cross-chain/HubDepositor.sol";
import {WithdrawalRegistry} from "../../src/core/cross-chain/WithdrawalRegistry.sol";
import {IWithdrawalRegistry} from "../../src/interfaces/cross-chain/IWithdrawalRegistry.sol";
import {MockRiskModule} from "../mocks/MockRiskModule.sol";
import {MockToken} from "../../src/mocks/MockToken.sol";

/// @title WithdrawalRegistryHandler
/// @notice Stateful fuzzing actor for the hub-only WithdrawalRegistry state
///         machine. Drives user requests + operator transitions and mirrors the
///         per-request status and per-user balance accounting in ghost state so
///         the invariant suite can prove WR-2 (debit-first / no double-withdraw)
///         and WR-4 (legal, terminal state transitions).
/// @dev Hub-only: every request targets `block.chainid`. The cross-chain
///      PROCESSING leg is out of audit scope, so the only states reachable here
///      are PENDING → {COMPLETED (authorize), FAILED (markFailed)}.
contract WithdrawalRegistryHandler is Test {
    BalanceLedger internal immutable ledger;
    WithdrawalRegistry internal immutable registry;
    MockRiskModule internal immutable risk;
    MockToken internal immutable token;
    address internal immutable operator;

    address[] public users;

    // Ghost: amount still "owed" by the registry per user — Σ amounts of that
    // user's requests not in the FAILED (refunded) state. available should equal
    // deposited − owed at all times.
    mapping(address => uint256) public ghostOwed;
    mapping(address => uint256) public deposited;

    // Ghost request registry.
    bytes32[] public requestIds;
    mapping(bytes32 => bool) internal _known;
    mapping(bytes32 => IWithdrawalRegistry.WithdrawalStatus) public ghostStatus;
    mapping(bytes32 => bool) public ghostTerminal;

    uint256 public requested;
    uint256 public completed;
    uint256 public failedCount;
    uint256 public blockedByHf;

    constructor(
        BalanceLedger ledger_,
        WithdrawalRegistry registry_,
        MockRiskModule risk_,
        MockToken token_,
        address operator_,
        address[] memory users_
    ) {
        ledger = ledger_;
        registry = registry_;
        risk = risk_;
        token = token_;
        operator = operator_;
        users = users_;
    }

    function _user(uint256 seed) internal view returns (address) {
        return users[bound(seed, 0, users.length - 1)];
    }

    function setDeposited(address user, uint256 amount) external {
        deposited[user] = amount;
    }

    // ---- User action: request a hub-native withdrawal ----
    function requestWithdrawal(uint256 userSeed, uint256 amount) external {
        address user = _user(userSeed);
        uint256 avail = ledger.available(user, address(token));
        if (avail == 0) return;
        amount = bound(amount, 1, avail);

        vm.prank(user);
        bytes32 id = registry.requestWithdrawal(address(token), amount, block.chainid);

        requestIds.push(id);
        _known[id] = true;
        ghostStatus[id] = IWithdrawalRegistry.WithdrawalStatus.PENDING;
        ghostOwed[user] += amount;
        requested++;
    }

    // ---- User action under a denying HF gate: must revert, must NOT mutate ----
    function requestWhileBlocked(uint256 userSeed, uint256 amount) external {
        address user = _user(userSeed);
        uint256 avail = ledger.available(user, address(token));
        if (avail == 0) return;
        amount = bound(amount, 1, avail);

        risk.setCanWithdraw(false);
        vm.prank(user);
        try registry.requestWithdrawal(address(token), amount, block.chainid) {
            // Should be unreachable — the HF gate is the first action.
            revert("HF gate failed to block");
        } catch {
            blockedByHf++;
        }
        risk.setCanWithdraw(true);
    }

    // ---- Operator action: authorize → COMPLETED (hub-native) ----
    function authorize(uint256 idSeed) external {
        bytes32 id = _pickPending(idSeed);
        if (id == bytes32(0)) return;

        vm.prank(operator);
        registry.authorize(id);

        ghostStatus[id] = IWithdrawalRegistry.WithdrawalStatus.COMPLETED;
        ghostTerminal[id] = true;
        completed++;
        // Owed stays debited — tokens were paid out, balance is not restored.
    }

    // ---- Operator action: markFailed → FAILED (refund) ----
    function markFailed(uint256 idSeed) external {
        bytes32 id = _pickPending(idSeed);
        if (id == bytes32(0)) return;

        IWithdrawalRegistry.WithdrawalRequest memory req = registry.getRequest(id);
        vm.prank(operator);
        registry.markFailed(id);

        ghostStatus[id] = IWithdrawalRegistry.WithdrawalStatus.FAILED;
        ghostTerminal[id] = true;
        ghostOwed[req.user] -= req.amount; // refunded back to available
        failedCount++;
    }

    /// @dev Linear scan for a still-PENDING request near `idSeed`. Returns
    ///      bytes32(0) when none exist (handler call becomes a no-op).
    function _pickPending(uint256 idSeed) internal view returns (bytes32) {
        uint256 n = requestIds.length;
        if (n == 0) return bytes32(0);
        uint256 start = bound(idSeed, 0, n - 1);
        for (uint256 i = 0; i < n; i++) {
            bytes32 id = requestIds[(start + i) % n];
            if (ghostStatus[id] == IWithdrawalRegistry.WithdrawalStatus.PENDING) {
                return id;
            }
        }
        return bytes32(0);
    }

    function requestCount() external view returns (uint256) {
        return requestIds.length;
    }

    function usersLength() external view returns (uint256) {
        return users.length;
    }
}

/// @title WithdrawalRegistryInvariantTest
/// @notice Invariant harness for the WithdrawalRegistry state machine (WR-2, WR-4)
///         on the hub-only path. Real BalanceLedger + HubDepositor + MockToken so
///         the debit/credit accounting is exercised end-to-end.
contract WithdrawalRegistryInvariantTest is StdInvariant, Test {
    BalanceLedger internal ledger;
    HubDepositor internal depositor;
    WithdrawalRegistry internal registry;
    MockRiskModule internal risk;
    MockToken internal token;
    WithdrawalRegistryHandler internal handler;

    address internal owner = address(0xA11CE);
    address internal operator = address(0x0BEE);

    address[] internal users;

    uint256 internal constant SEED_DEPOSIT = 1_000_000e6;

    function setUp() public {
        token = new MockToken("USD Coin", "USDC", 6, 0);

        // BalanceLedger
        BalanceLedger ledgerImpl = new BalanceLedger();
        bytes memory ledgerInit = abi.encodeCall(BalanceLedger.initialize, (owner, true));
        ledger = BalanceLedger(address(new TransparentUpgradeableProxy(address(ledgerImpl), address(this), ledgerInit)));

        // HubDepositor
        HubDepositor depImpl = new HubDepositor();
        bytes memory depInit = abi.encodeCall(HubDepositor.initialize, (owner, address(ledger)));
        depositor = HubDepositor(address(new TransparentUpgradeableProxy(address(depImpl), address(this), depInit)));

        // Permissive risk module (the handler toggles it to drive the deny path).
        risk = new MockRiskModule();

        // WithdrawalRegistry
        WithdrawalRegistry regImpl = new WithdrawalRegistry();
        bytes memory regInit = abi.encodeCall(
            WithdrawalRegistry.initialize, (owner, operator, address(ledger), address(risk), address(depositor))
        );
        registry =
            WithdrawalRegistry(address(new TransparentUpgradeableProxy(address(regImpl), address(this), regInit)));

        vm.startPrank(owner);
        ledger.forceAddWriter(address(depositor));
        ledger.forceAddWriter(address(registry));
        depositor.addSupportedAsset(address(token));
        depositor.setAuthorizedCaller(address(registry), true);
        vm.stopPrank();

        users.push(address(0x1111));
        users.push(address(0x2222));
        users.push(address(0x3333));

        handler = new WithdrawalRegistryHandler(ledger, registry, risk, token, operator, users);

        // Seed each user with a real deposit so the registry can debit/credit.
        for (uint256 i = 0; i < users.length; i++) {
            address u = users[i];
            token.mint(u, SEED_DEPOSIT);
            vm.startPrank(u);
            token.approve(address(depositor), SEED_DEPOSIT);
            depositor.deposit(address(token), SEED_DEPOSIT);
            vm.stopPrank();
            handler.setDeposited(u, SEED_DEPOSIT);
        }

        // Constrain fuzzing to the four state-machine entry points (exclude the
        // setDeposited bookkeeping helper, which is only used during setup).
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.requestWithdrawal.selector;
        selectors[1] = handler.requestWhileBlocked.selector;
        selectors[2] = handler.authorize.selector;
        selectors[3] = handler.markFailed.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice WR-2: every request debits up front and only a FAILED request is
    ///         refunded. Therefore `available == deposited − Σ(non-failed amounts)`
    ///         for every user — no double-withdrawal can leak balance.
    function invariant_WR2_balanceAccountingReconciles() public view {
        for (uint256 i = 0; i < users.length; i++) {
            address u = users[i];
            assertEq(
                ledger.available(u, address(token)),
                handler.deposited(u) - handler.ghostOwed(u),
                "available != deposited - outstanding owed"
            );
        }
    }

    /// @notice WR-4: hub-only never reaches PROCESSING, and the on-chain status
    ///         always matches the ghost mirror of legal transitions.
    function invariant_WR4_statusMachineConsistent() public view {
        uint256 n = handler.requestCount();
        for (uint256 i = 0; i < n; i++) {
            bytes32 id = handler.requestIds(i);
            IWithdrawalRegistry.WithdrawalStatus onchain = registry.getRequest(id).status;
            assertTrue(
                onchain != IWithdrawalRegistry.WithdrawalStatus.PROCESSING, "hub-only path must never reach PROCESSING"
            );
            assertEq(uint8(onchain), uint8(handler.ghostStatus(id)), "on-chain status diverged from legal transitions");
        }
    }

    /// @notice WR-4: COMPLETED and FAILED are terminal — once terminal, a request
    ///         never regresses to a non-terminal state.
    function invariant_WR4_terminalNeverRegresses() public view {
        uint256 n = handler.requestCount();
        for (uint256 i = 0; i < n; i++) {
            bytes32 id = handler.requestIds(i);
            if (handler.ghostTerminal(id)) {
                IWithdrawalRegistry.WithdrawalStatus s = registry.getRequest(id).status;
                assertTrue(
                    s == IWithdrawalRegistry.WithdrawalStatus.COMPLETED
                        || s == IWithdrawalRegistry.WithdrawalStatus.FAILED,
                    "terminal request regressed to non-terminal status"
                );
            }
        }
    }
}
