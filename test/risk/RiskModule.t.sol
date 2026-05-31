// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {RiskModule} from "../../src/core/risk/RiskModule.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";

/// @notice Minimal stand-ins exposing only the selectors RiskModule calls.
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

    function setUsed(address user, address asset, bool v) external {
        _used[user][asset] = v;
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

contract RiskModuleTest is Test {
    RiskModule internal rm;
    MockLedger internal ledger;
    MockCentuariDebt internal centuari;
    MockPriceOracle internal px;

    address internal owner = makeAddr("owner");
    address internal proxyAdminOwner = makeAddr("proxyAdminOwner");
    address internal stranger = makeAddr("stranger");
    address internal user = makeAddr("user");

    address internal COLL = makeAddr("COLL");
    address internal COLL2 = makeAddr("COLL2");
    address internal FREE = makeAddr("FREE");
    address internal DEBT = makeAddr("DEBT");

    function setUp() public {
        ledger = new MockLedger();
        centuari = new MockCentuariDebt();
        px = new MockPriceOracle();

        RiskModule impl = new RiskModule();
        bytes memory initData =
            abi.encodeCall(RiskModule.initialize, (owner, address(px), address(centuari), address(ledger)));
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(impl), proxyAdminOwner, initData);
        rm = RiskModule(address(proxy));

        // Deterministic math: zero buffer unless a test sets it.
        vm.startPrank(owner);
        rm.setDefaultBuffer(0);
        rm.setLtv(COLL, 8000); // 80%
        rm.setLtv(COLL2, 8000);
        vm.stopPrank();

        // $1 prices for everything by default.
        px.set(COLL, 1e18, true);
        px.set(COLL2, 1e18, true);
        px.set(DEBT, 1e18, true);
        px.set(FREE, 1e18, true);
    }

    // ---- helpers ----

    function _one(address x) internal pure returns (address[] memory a) {
        a = new address[](1);
        a[0] = x;
    }

    function _two(address x, address y) internal pure returns (address[] memory a) {
        a = new address[](2);
        a[0] = x;
        a[1] = y;
    }

    function _debt(address token, uint256 amt) internal {
        address[] memory t = new address[](1);
        t[0] = token;
        uint256[] memory v = new uint256[](1);
        v[0] = amt;
        centuari.setDebts(user, t, v);
    }

    // ---- tests ----

    function test_noDebt_flaggedAsset_alwaysWithdrawable() public {
        ledger.setFlagged(user, _one(COLL));
        ledger.setAvailable(user, COLL, 100e18);
        // no debt set

        assertTrue(rm.canWithdraw(user, COLL, 100e18));
        assertTrue(rm.canUnflag(user, COLL));
    }

    function test_nonCollateralAsset_alwaysWithdrawable_evenWithDebt() public {
        ledger.setFlagged(user, _one(COLL));
        ledger.setAvailable(user, COLL, 100e18);
        ledger.setAvailable(user, FREE, 50e18);
        _debt(DEBT, 40e18);
        // FREE is not flagged
        assertFalse(ledger.usedAsCollateral(user, FREE));
        assertTrue(rm.canWithdraw(user, FREE, 50e18));
    }

    /// @dev The behavior IMPOSSIBLE under RiskModuleStub: a flagged collateral
    ///      asset can be partially withdrawn while in debt, because post-action
    ///      HF stays ≥ 1.
    function test_flaggedHealthyWithdrawal_succeeds() public {
        ledger.setFlagged(user, _one(COLL));
        ledger.setAvailable(user, COLL, 100e18);
        _debt(DEBT, 40e18);

        // HF after withdrawing 5: (95-40)*0.8/40 = 1.1 ≥ 1.0
        assertTrue(rm.canWithdraw(user, COLL, 5e18));
    }

    function test_withdrawal_isAmountAware_atBoundary() public {
        ledger.setFlagged(user, _one(COLL));
        ledger.setAvailable(user, COLL, 100e18);
        _debt(DEBT, 40e18);

        // withdraw 10: HF = (90-40)*0.8/40 = 1.0 exactly → allowed (buffer 0)
        assertTrue(rm.canWithdraw(user, COLL, 10e18));
        // withdraw 11: HF = (89-40)*0.8/40 = 0.98 → blocked
        assertFalse(rm.canWithdraw(user, COLL, 11e18));
    }

    function test_withdrawal_breakingHF_blocked() public {
        ledger.setFlagged(user, _one(COLL));
        ledger.setAvailable(user, COLL, 100e18);
        _debt(DEBT, 40e18);
        // withdraw 50: HF = (50-40)*0.8/40 = 0.2 → blocked
        assertFalse(rm.canWithdraw(user, COLL, 50e18));
    }

    function test_buffer_raisesThreshold() public {
        ledger.setFlagged(user, _one(COLL));
        ledger.setAvailable(user, COLL, 100e18);
        _debt(DEBT, 40e18);

        // withdraw 10 → HF exactly 1.0; with a 100bps buffer threshold is 1.01 → blocked
        vm.prank(owner);
        rm.setBuffer(COLL, 100);
        assertFalse(rm.canWithdraw(user, COLL, 10e18));
    }

    function test_canUnflag_healthy_true() public {
        ledger.setFlagged(user, _two(COLL, COLL2));
        ledger.setAvailable(user, COLL, 100e18);
        ledger.setAvailable(user, COLL2, 100e18);
        _debt(DEBT, 40e18);

        // remove COLL2 → remaining 100 collateral: HF = (100-40)*0.8/40 = 1.2 ≥ 1.0
        assertTrue(rm.canUnflag(user, COLL2));
    }

    function test_canUnflag_unhealthy_false() public {
        ledger.setFlagged(user, _two(COLL, COLL2));
        ledger.setAvailable(user, COLL, 100e18);
        ledger.setAvailable(user, COLL2, 100e18);
        _debt(DEBT, 70e18);

        // both flagged: HF = (200-70)*0.8/70 ≈ 1.49 (healthy)
        // remove COLL2 → HF = (100-70)*0.8/70 ≈ 0.34 → blocked
        assertFalse(rm.canUnflag(user, COLL2));
    }

    function test_failClosed_staleCollateralPrice() public {
        ledger.setFlagged(user, _one(COLL));
        ledger.setAvailable(user, COLL, 100e18);
        _debt(DEBT, 40e18);

        px.set(COLL, 1e18, false); // collateral price not ok
        assertFalse(rm.canWithdraw(user, COLL, 1e18));
        assertFalse(rm.canUnflag(user, COLL));
    }

    function test_failClosed_staleDebtPrice() public {
        ledger.setFlagged(user, _one(COLL));
        ledger.setAvailable(user, COLL, 100e18);
        _debt(DEBT, 40e18);

        px.set(DEBT, 1e18, false); // debt price not ok
        assertFalse(rm.canWithdraw(user, COLL, 1e18));
    }

    function test_zeroLtvCollateral_blocksWhenInDebt() public {
        vm.prank(owner);
        rm.setLtv(COLL, 0); // no borrowing power
        ledger.setFlagged(user, _one(COLL));
        ledger.setAvailable(user, COLL, 100e18);
        _debt(DEBT, 1e18);

        assertFalse(rm.canWithdraw(user, COLL, 1e18));
    }

    function test_setters_onlyOwner() public {
        vm.startPrank(stranger);
        vm.expectRevert();
        rm.setLtv(COLL, 5000);
        vm.expectRevert();
        rm.setBuffer(COLL, 50);
        vm.expectRevert();
        rm.setOracle(address(px));
        vm.expectRevert();
        rm.setDefaultBuffer(0);
        vm.stopPrank();
    }

    function test_setLtv_rejectsAboveBps() public {
        vm.prank(owner);
        vm.expectRevert(RiskModule.InvalidBps.selector);
        rm.setLtv(COLL, 10001);
    }

    function test_initialize_rejectsZeroDeps() public {
        RiskModule impl = new RiskModule();
        bytes memory bad =
            abi.encodeCall(RiskModule.initialize, (owner, address(0), address(centuari), address(ledger)));
        vm.expectRevert(RiskModule.ZeroAddress.selector);
        new TransparentUpgradeableProxy(address(impl), proxyAdminOwner, bad);
    }

    function test_views_exposeWiring() public view {
        assertEq(rm.oracle(), address(px));
        assertEq(rm.centuari(), address(centuari));
        assertEq(rm.balanceLedger(), address(ledger));
        assertEq(rm.ltvBps(COLL), 8000);
        assertEq(rm.defaultBufferBps(), 0);
    }

    // ---- isLiquidatable / healthFactor (liquidation trigger) ----

    function test_isLiquidatable_noDebt_false() public {
        ledger.setFlagged(user, _one(COLL));
        ledger.setAvailable(user, COLL, 100e18);
        // no debt set
        assertFalse(rm.isLiquidatable(user));
        assertEq(rm.healthFactor(user), type(uint256).max);
    }

    function test_isLiquidatable_healthy_false() public {
        ledger.setFlagged(user, _one(COLL));
        ledger.setAvailable(user, COLL, 100e18);
        _debt(DEBT, 40e18);
        // HF = (100-40)*0.8/40 = 1.2 ≥ 1.0 → not liquidatable
        assertEq(rm.healthFactor(user), 1.2e18);
        assertFalse(rm.isLiquidatable(user));
    }

    function test_isLiquidatable_atExactlyOne_false() public {
        ledger.setFlagged(user, _one(COLL));
        ledger.setAvailable(user, COLL, 90e18);
        _debt(DEBT, 40e18);
        // HF = (90-40)*0.8/40 = 1.0 exactly → NOT liquidatable (trigger is hf < 1.0)
        assertEq(rm.healthFactor(user), 1e18);
        assertFalse(rm.isLiquidatable(user));
    }

    function test_isLiquidatable_belowOne_true() public {
        ledger.setFlagged(user, _one(COLL));
        ledger.setAvailable(user, COLL, 100e18);
        _debt(DEBT, 50e18);
        // HF = (100-50)*0.8/50 = 0.8 < 1.0 → liquidatable
        assertEq(rm.healthFactor(user), 0.8e18);
        assertTrue(rm.isLiquidatable(user));
    }

    function test_isLiquidatable_underwater_true() public {
        ledger.setFlagged(user, _one(COLL));
        ledger.setAvailable(user, COLL, 30e18);
        _debt(DEBT, 40e18);
        // collateralUsd (30) <= debtUsd (40) → underwater → liquidatable, HF reported as 0
        assertTrue(rm.isLiquidatable(user));
        assertEq(rm.healthFactor(user), 0);
    }

    function test_isLiquidatable_buffer_ignoredForTrigger() public {
        ledger.setFlagged(user, _one(COLL));
        ledger.setAvailable(user, COLL, 90e18);
        _debt(DEBT, 40e18);
        // HF = 1.0 exactly. The withdraw/borrow buffer must NOT make this liquidatable:
        // the liquidation trigger is hf < 1.0 with NO buffer.
        vm.prank(owner);
        rm.setBuffer(COLL, 100); // 1.01 withdraw threshold
        assertFalse(rm.isLiquidatable(user));
    }

    function test_isLiquidatable_failClosed_staleDebtPrice() public {
        ledger.setFlagged(user, _one(COLL));
        ledger.setAvailable(user, COLL, 30e18);
        _debt(DEBT, 40e18);
        px.set(DEBT, 1e18, false); // debt unpriced
        // Underwater on paper, but price is stale → fail-closed = NOT liquidatable
        assertFalse(rm.isLiquidatable(user));
        assertEq(rm.healthFactor(user), 0);
    }

    function test_isLiquidatable_failClosed_staleCollateralPrice() public {
        ledger.setFlagged(user, _one(COLL));
        ledger.setAvailable(user, COLL, 100e18);
        _debt(DEBT, 50e18);
        px.set(COLL, 1e18, false); // collateral unpriced
        assertFalse(rm.isLiquidatable(user));
    }

    function test_canWithdraw_unchanged_afterRefactor() public {
        // Regression: the existing HF gate behavior must be preserved after the
        // _healthyAfter → _computeHf refactor.
        ledger.setFlagged(user, _one(COLL));
        ledger.setAvailable(user, COLL, 100e18);
        _debt(DEBT, 40e18);
        assertTrue(rm.canWithdraw(user, COLL, 10e18)); // HF 1.0 at buffer 0 → allowed
        assertFalse(rm.canWithdraw(user, COLL, 11e18)); // HF 0.98 → blocked
    }
}
