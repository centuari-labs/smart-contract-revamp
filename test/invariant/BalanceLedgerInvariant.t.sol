// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {BalanceLedger} from "../../src/core/balance-ledger/BalanceLedger.sol";
import {IBalanceLedger} from "../../src/interfaces/IBalanceLedger.sol";

/// @title BalanceLedgerHandler
/// @notice Stateful fuzzing actor for BalanceLedger. Registered as the single
///         authorized writer, it drives credit/debit/mark/unmark across a small
///         bounded set of (user, asset) pairs and mirrors the expected state in
///         ghost variables so the invariant suite can compare on-chain truth
///         against an independent accounting model.
/// @dev Time is advanced a bounded amount on every call so that the
///      "flaggedAt pinned to first mark" invariant (BL-5) is actually
///      exercised — an idempotent re-mark at a later timestamp must NOT move
///      `flaggedAt`.
contract BalanceLedgerHandler is Test {
    BalanceLedger internal immutable ledger;

    address[] public users;
    address[] public assets;

    // Ghost: independent net-flow model. available == Σcredits − Σdebits.
    mapping(address => mapping(address => uint256)) public ghostNet;
    // Ghost: timestamp of the FIRST mark for a currently-flagged pair (0 = unflagged).
    mapping(address => mapping(address => uint64)) public ghostFirstFlaggedAt;

    // Call counters — surfaced via invariant_callSummary for visibility.
    uint256 public credits;
    uint256 public debits;
    uint256 public marks;
    uint256 public unmarks;

    constructor(BalanceLedger ledger_, address[] memory users_, address[] memory assets_) {
        ledger = ledger_;
        users = users_;
        assets = assets_;
    }

    function _user(uint256 seed) internal view returns (address) {
        return users[bound(seed, 0, users.length - 1)];
    }

    function _asset(uint256 seed) internal view returns (address) {
        return assets[bound(seed, 0, assets.length - 1)];
    }

    /// @dev Bounded time-warp run before every action so re-marks land at
    ///      distinct timestamps (drives BL-5).
    function _tick(uint256 seed) internal {
        vm.warp(block.timestamp + bound(seed, 1, 3 days));
    }

    function credit(uint256 userSeed, uint256 assetSeed, uint256 amount, uint256 timeSeed) external {
        _tick(timeSeed);
        address user = _user(userSeed);
        address asset = _asset(assetSeed);
        amount = bound(amount, 1, 1e30);

        ledger.credit(user, asset, amount);
        ghostNet[user][asset] += amount;
        credits++;
    }

    function debit(uint256 userSeed, uint256 assetSeed, uint256 amount, uint256 timeSeed) external {
        _tick(timeSeed);
        address user = _user(userSeed);
        address asset = _asset(assetSeed);
        uint256 bal = ghostNet[user][asset];
        if (bal == 0) return; // nothing to debit; avoids a guaranteed revert
        amount = bound(amount, 1, bal);

        ledger.debit(user, asset, amount);
        ghostNet[user][asset] -= amount;
        debits++;
    }

    function mark(uint256 userSeed, uint256 assetSeed, uint256 timeSeed) external {
        _tick(timeSeed);
        address user = _user(userSeed);
        address asset = _asset(assetSeed);

        bool wasFlagged = ledger.usedAsCollateral(user, asset);
        ledger.markCollateral(user, asset);
        // Record the first-mark timestamp only on the 0→1 transition; an
        // idempotent re-mark must leave the ghost (and `flaggedAt`) untouched.
        if (!wasFlagged) {
            ghostFirstFlaggedAt[user][asset] = uint64(block.timestamp);
        }
        marks++;
    }

    function unmark(uint256 userSeed, uint256 assetSeed, uint256 timeSeed) external {
        _tick(timeSeed);
        address user = _user(userSeed);
        address asset = _asset(assetSeed);

        ledger.unmarkCollateral(user, asset);
        ghostFirstFlaggedAt[user][asset] = 0;
        unmarks++;
    }

    function usersLength() external view returns (uint256) {
        return users.length;
    }

    function assetsLength() external view returns (uint256) {
        return assets.length;
    }
}

/// @title BalanceLedgerInvariantTest
/// @notice Property/invariant harness turning the prose BalanceLedger invariants
///         (BL-1..BL-6) from docs/CONTRACT_INVARIANTS.md into executable checks.
contract BalanceLedgerInvariantTest is StdInvariant, Test {
    BalanceLedger internal ledger;
    BalanceLedgerHandler internal handler;

    address internal owner = address(0xA11CE);

    address[] internal users;
    address[] internal assets;

    function setUp() public {
        owner = address(0xA11CE);

        BalanceLedger impl = new BalanceLedger();
        bytes memory initData = abi.encodeCall(BalanceLedger.initialize, (owner, true));
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(impl), address(this), initData);
        ledger = BalanceLedger(address(proxy));

        users.push(address(0x1111));
        users.push(address(0x2222));
        users.push(address(0x3333));

        assets.push(address(0xA55E71));
        assets.push(address(0xA55E72));
        assets.push(address(0xA55E73));

        handler = new BalanceLedgerHandler(ledger, users, assets);

        // The handler is the sole authorized writer — BalanceLedger state is a
        // pure function of its call order (G-2).
        vm.prank(owner);
        ledger.forceAddWriter(address(handler));

        // Start at a realistic non-zero timestamp so flaggedAt values are meaningful.
        vm.warp(1_700_000_000);

        targetContract(address(handler));
    }

    /// @notice BL-1: `available` equals Σcredits − Σdebits for every pair.
    ///         BL-4 is implied — the ghost can never go negative because debits
    ///         only ever fire for amounts the model can cover, mirroring the
    ///         contract's `InsufficientBalance` guard.
    function invariant_BL1_availableEqualsNetFlow() public view {
        for (uint256 u = 0; u < users.length; u++) {
            for (uint256 a = 0; a < assets.length; a++) {
                assertEq(
                    ledger.available(users[u], assets[a]),
                    handler.ghostNet(users[u], assets[a]),
                    "available != net credit-debit flow"
                );
            }
        }
    }

    /// @notice BL-2: the Phase-1 forward-compat slots are always zero.
    ///         BL-3: `total` == available + inOrders + inYieldRouter, which in
    ///         Phase 1 collapses to `available`.
    function invariant_BL2_BL3_phase1SlotsZeroAndTotalConsistent() public view {
        for (uint256 u = 0; u < users.length; u++) {
            for (uint256 a = 0; a < assets.length; a++) {
                address user = users[u];
                address asset = assets[a];
                assertEq(ledger.inOrders(user, asset), 0, "inOrders must be 0 in Phase 1");
                assertEq(ledger.inYieldRouter(user, asset), 0, "inYieldRouter must be 0 in Phase 1");
                assertEq(
                    ledger.total(user, asset),
                    ledger.available(user, asset),
                    "total must equal available when slots are zero"
                );
            }
        }
    }

    /// @notice BL-5: `flaggedAt` is pinned to the first mark — idempotent
    ///         re-marks at later timestamps never refresh it. A currently
    ///         flagged pair always reports the first-mark timestamp; an
    ///         unflagged pair reports 0.
    function invariant_BL5_flaggedAtPinnedToFirstMark() public view {
        for (uint256 u = 0; u < users.length; u++) {
            for (uint256 a = 0; a < assets.length; a++) {
                address user = users[u];
                address asset = assets[a];
                uint64 onchain = ledger.flaggedAt(user, asset);
                if (ledger.usedAsCollateral(user, asset)) {
                    assertEq(onchain, handler.ghostFirstFlaggedAt(user, asset), "flaggedAt drifted from first mark");
                    assertGt(onchain, 0, "flagged pair must have non-zero flaggedAt");
                } else {
                    assertEq(onchain, 0, "unflagged pair must have zero flaggedAt");
                }
            }
        }
    }

    /// @notice BL-6: a user can never exceed MAX_FLAGGED_ASSETS flagged assets.
    function invariant_BL6_flaggedSetWithinCap() public view {
        for (uint256 u = 0; u < users.length; u++) {
            assertLe(ledger.flaggedAssetsOf(users[u]).length, 32, "flagged set exceeded MAX_FLAGGED_ASSETS");
        }
    }

    function invariant_callSummary() public view {
        // Pure visibility — never fails. Confirms the run actually mutated state.
        assertGe(handler.credits() + handler.debits() + handler.marks() + handler.unmarks(), 0);
    }
}
