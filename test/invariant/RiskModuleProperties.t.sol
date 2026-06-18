// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {RiskModule} from "../../src/core/risk/RiskModule.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";

/// @notice Minimal BalanceLedger stand-in exposing only the selectors RiskModule
///         reads (flagged set, collateral flag, available balance).
contract MockLedger {
    mapping(address => address[]) internal _flagged;
    mapping(address => mapping(address => bool)) internal _used;
    mapping(address => mapping(address => uint256)) internal _avail;

    function setFlagged(address user, address[] calldata assets) external {
        _flagged[user] = assets;
        for (uint256 i; i < assets.length; ++i) {
            _used[user][assets[i]] = true;
        }
    }

    function setAvailable(address user, address asset, uint256 amt) external {
        _avail[user][asset] = amt;
    }

    function flaggedAssetsOf(address user) external view returns (address[] memory) {
        return _flagged[user];
    }

    function usedAsCollateral(address user, address asset) external view returns (bool) {
        return _used[user][asset];
    }

    function available(address user, address asset) external view returns (uint256) {
        return _avail[user][asset];
    }
}

/// @notice Per-user debt source stand-in for Centuari.
contract MockCentuariDebt {
    mapping(address => address[]) internal _tokens;
    mapping(address => uint256[]) internal _amounts;

    function setDebts(address user, address[] calldata tokens, uint256[] calldata amounts) external {
        _tokens[user] = tokens;
        _amounts[user] = amounts;
    }

    function getBorrowerDebts(address user) external view returns (address[] memory, uint256[] memory) {
        return (_tokens[user], _amounts[user]);
    }
}

/// @notice Configurable price oracle: `ok=false` models a missing/stale feed.
contract MockPriceOracle is IPriceOracle {
    mapping(address => uint256) public price; // 1e18 USD per whole (18-dec) token
    mapping(address => bool) public ok;

    function set(address asset, uint256 p, bool ok_) external {
        price[asset] = p;
        ok[asset] = ok_;
    }

    function tryGetUsdValue(address asset, uint256 amount) external view returns (uint256, bool) {
        if (!ok[asset]) return (0, false);
        return (amount * price[asset] / 1e18, true);
    }
}

/// @title RiskModulePropertiesTest
/// @notice Fuzz property harness for the RiskModule HF policy (RM-1, RM-2, RM-4,
///         RM-5 from docs/CONTRACT_INVARIANTS.md). RiskModule is a stateless view
///         policy, so these are property-based fuzz tests rather than a stateful
///         StdInvariant handler — the decision path is exercised over a wide range
///         of prices, debts and collateral amounts.
contract RiskModulePropertiesTest is Test {
    RiskModule internal rm;
    MockLedger internal ledger;
    MockCentuariDebt internal centuari;
    MockPriceOracle internal px;

    address internal owner = makeAddr("owner");
    address internal user = makeAddr("user");

    address internal COLL = makeAddr("COLL");
    address internal DEBT = makeAddr("DEBT");

    function setUp() public {
        ledger = new MockLedger();
        centuari = new MockCentuariDebt();
        px = new MockPriceOracle();

        RiskModule impl = new RiskModule();
        bytes memory initData =
            abi.encodeCall(RiskModule.initialize, (owner, address(px), address(centuari), address(ledger)));
        rm = RiskModule(address(new TransparentUpgradeableProxy(address(impl), makeAddr("proxyAdmin"), initData)));

        // Zero buffer for deterministic threshold math; 80% LTV on collateral.
        vm.startPrank(owner);
        rm.setDefaultBuffer(0);
        rm.setLtv(COLL, 8000);
        vm.stopPrank();
    }

    // ---- helpers ----

    function _flag(address asset) internal {
        address[] memory a = new address[](1);
        a[0] = asset;
        ledger.setFlagged(user, a);
    }

    function _setDebt(address token, uint256 amount) internal {
        address[] memory t = new address[](1);
        uint256[] memory am = new uint256[](1);
        t[0] = token;
        am[0] = amount;
        centuari.setDebts(user, t, am);
    }

    /// @notice RM-2 / G-6: a user with no active debt is always healthy and is
    ///         NEVER fail-closed out — even when every collateral price is stale.
    ///         Debt is read first, so an unpriced collateral feed can't matter.
    function testFuzz_RM2_zeroDebtAlwaysHealthy(uint256 collAmt, uint256 collPrice, bool collOk) public {
        collAmt = bound(collAmt, 0, 1e30);
        collPrice = bound(collPrice, 0, 1e24);
        _flag(COLL);
        ledger.setAvailable(user, COLL, collAmt);
        px.set(COLL, collPrice, collOk); // may be stale/zero — must not matter
        // No debts set → getBorrowerDebts returns empty.

        assertTrue(rm.canWithdraw(user, COLL, collAmt), "zero-debt user must be allowed to withdraw");
        assertTrue(rm.canUnflag(user, COLL), "zero-debt user must be allowed to unflag");
        assertEq(rm.healthFactor(user), type(uint256).max, "zero-debt HF must be max");
        assertFalse(rm.isLiquidatable(user), "zero-debt user is never liquidatable");
    }

    /// @notice RM-1 / G-6: a missing/stale DEBT price fails closed — the decision
    ///         returns false (and HF 0 / not liquidatable) without reverting.
    function testFuzz_RM1_failClosedOnStaleDebtPrice(uint256 debtAmt, uint256 collAmt) public {
        debtAmt = bound(debtAmt, 1, 1e30);
        collAmt = bound(collAmt, 1, 1e30);

        _flag(COLL);
        ledger.setAvailable(user, COLL, collAmt);
        px.set(COLL, 1e18, true);
        _setDebt(DEBT, debtAmt);
        px.set(DEBT, 1e18, false); // stale/missing debt feed

        assertFalse(rm.canWithdraw(user, COLL, 0), "stale debt price must fail closed (canWithdraw)");
        assertFalse(rm.canUnflag(user, COLL), "stale debt price must fail closed (canUnflag)");
        assertEq(rm.healthFactor(user), 0, "stale debt price must yield HF 0");
        assertFalse(rm.isLiquidatable(user), "fail-closed must never liquidate");
    }

    /// @notice RM-1 / G-6: a missing/stale COLLATERAL price (with real debt) also
    ///         fails closed on withdraw/unflag.
    function testFuzz_RM1_failClosedOnStaleCollateralPrice(uint256 debtAmt, uint256 collAmt) public {
        debtAmt = bound(debtAmt, 1, 1e30);
        collAmt = bound(collAmt, 1, 1e30);

        _flag(COLL);
        ledger.setAvailable(user, COLL, collAmt);
        px.set(COLL, 1e18, false); // stale collateral feed
        _setDebt(DEBT, debtAmt);
        px.set(DEBT, 1e18, true);

        assertFalse(rm.canWithdraw(user, COLL, 0), "stale collateral price must fail closed (canWithdraw)");
        assertFalse(rm.canUnflag(user, COLL), "stale collateral price must fail closed (canUnflag)");
    }

    /// @notice RM-4 monotonicity: with fixed debt, more collateral value can only
    ///         hold or raise the health factor — never lower it.
    function testFuzz_RM4_moreCollateralNonDecreasingHF(uint256 collA, uint256 collB, uint256 debtAmt) public {
        debtAmt = bound(debtAmt, 1e6, 1e24);
        collA = bound(collA, 1, 1e24);
        collB = bound(collB, collA, 1e24); // collB >= collA

        _flag(COLL);
        px.set(COLL, 1e18, true);
        _setDebt(DEBT, debtAmt);
        px.set(DEBT, 1e18, true);

        ledger.setAvailable(user, COLL, collA);
        uint256 hfA = rm.healthFactor(user);
        ledger.setAvailable(user, COLL, collB);
        uint256 hfB = rm.healthFactor(user);

        assertGe(hfB, hfA, "more collateral must not decrease HF");
    }

    /// @notice RM-4 monotonicity: with fixed collateral, more debt can only hold
    ///         or lower the health factor — never raise it.
    function testFuzz_RM4_moreDebtNonIncreasingHF(uint256 debtA, uint256 debtB, uint256 collAmt) public {
        collAmt = bound(collAmt, 1e6, 1e24);
        debtA = bound(debtA, 1, 1e24);
        debtB = bound(debtB, debtA, 1e24); // debtB >= debtA

        _flag(COLL);
        ledger.setAvailable(user, COLL, collAmt);
        px.set(COLL, 1e18, true);
        px.set(DEBT, 1e18, true);

        _setDebt(DEBT, debtA);
        uint256 hfA = rm.healthFactor(user);
        _setDebt(DEBT, debtB);
        uint256 hfB = rm.healthFactor(user);

        assertLe(hfB, hfA, "more debt must not increase HF");
    }

    /// @notice RM-5: the liquidation floor is exactly HF < 1.0. For a priced user
    ///         with debt, `isLiquidatable` agrees with `healthFactor < 1e18`.
    function testFuzz_RM5_liquidationFloorMatchesHF(uint256 collAmt, uint256 debtAmt) public {
        collAmt = bound(collAmt, 1, 1e24);
        debtAmt = bound(debtAmt, 1, 1e24);

        _flag(COLL);
        ledger.setAvailable(user, COLL, collAmt);
        px.set(COLL, 1e18, true);
        _setDebt(DEBT, debtAmt);
        px.set(DEBT, 1e18, true);

        uint256 hf = rm.healthFactor(user);
        assertEq(rm.isLiquidatable(user), hf < 1e18, "isLiquidatable must equal HF < 1.0 for priced debt");
    }
}
