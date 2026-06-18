// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {LiquidationEngine} from "../../src/core/liquidation/LiquidationEngine.sol";
import {ILiquidationEngine} from "../../src/interfaces/ILiquidationEngine.sol";

/// @notice Decimals-aware oracle mock: value1e18 = amount * price / 10**dec.
contract MockLEOracle {
    mapping(address => uint256) internal _price; // 1e18 USD per whole token
    mapping(address => uint8) internal _dec;
    mapping(address => bool) internal _ok;

    function set(address asset, uint256 price1e18, uint8 dec, bool ok) external {
        _price[asset] = price1e18;
        _dec[asset] = dec;
        _ok[asset] = ok;
    }

    function tryGetUsdValue(address asset, uint256 amount) external view returns (uint256, bool) {
        if (!_ok[asset]) return (0, false);
        return (Math.mulDiv(amount, _price[asset], 10 ** _dec[asset]), true);
    }
}

/// @notice Minimal BalanceLedger mock (available + collateral flag + credit/debit).
contract MockLELedger {
    mapping(address => mapping(address => uint256)) public avail;
    mapping(address => mapping(address => bool)) public used;

    function setAvailable(address u, address a, uint256 amt) external {
        avail[u][a] = amt;
    }

    function setUsed(address u, address a, bool v) external {
        used[u][a] = v;
    }

    function credit(address u, address a, uint256 amt) external {
        avail[u][a] += amt;
    }

    function debit(address u, address a, uint256 amt) external {
        require(avail[u][a] >= amt, "insufficient");
        avail[u][a] -= amt;
    }

    function markCollateral(address u, address a) external {
        used[u][a] = true;
    }

    function unmarkCollateral(address u, address a) external {
        used[u][a] = false;
    }

    function available(address u, address a) external view returns (uint256) {
        return avail[u][a];
    }

    function usedAsCollateral(address u, address a) external view returns (bool) {
        return used[u][a];
    }
}

/// @notice Centuari mock: market id + debt + liquidationRepay (debits liquidator).
contract MockLECentuari {
    MockLELedger public ledger;
    mapping(bytes32 => mapping(address => uint256)) public debt;

    constructor(MockLELedger _ledger) {
        ledger = _ledger;
    }

    function setDebt(bytes32 marketId, address borrower, uint256 amt) external {
        debt[marketId][borrower] = amt;
    }

    function getMarketId(address loanToken, uint256 maturity) external pure returns (bytes32) {
        return keccak256(abi.encode(loanToken, maturity));
    }

    function getBorrowPosition(bytes32 marketId, address borrower) external view returns (uint256) {
        return debt[marketId][borrower];
    }

    function liquidationRepay(bytes32 marketId, address borrower, address loanToken, address liquidator, uint256 amount)
        external
    {
        uint256 d = debt[marketId][borrower];
        uint256 r = amount > d ? d : amount;
        debt[marketId][borrower] = d - r;
        ledger.debit(liquidator, loanToken, r); // liquidator funds the repay
    }
}

/// @notice RiskModule mock exposing only isLiquidatable.
contract MockLERisk {
    mapping(address => bool) internal _liq;

    function setLiquidatable(address u, bool v) external {
        _liq[u] = v;
    }

    function isLiquidatable(address u) external view returns (bool) {
        return _liq[u];
    }
}

contract LiquidationEngineTest is Test {
    LiquidationEngine internal engine;
    MockLEOracle internal oracle;
    MockLELedger internal ledger;
    MockLECentuari internal centuari;
    MockLERisk internal risk;

    address internal owner = makeAddr("owner");
    address internal pauser = makeAddr("pauser");
    address internal proxyAdmin = makeAddr("proxyAdmin");
    address internal borrower = makeAddr("borrower");
    address internal liquidator = makeAddr("liquidator");

    address internal LOAN = makeAddr("LOAN"); // 18 dec, $1
    address internal COLL = makeAddr("COLL"); // 18 dec, $1
    address internal COLL6 = makeAddr("COLL6"); // 6 dec, $1

    uint256 internal constant BONUS = 800; // 8%
    uint256 internal constant HF_CF = 5000; // 50%
    uint256 internal constant MAT_CF = 10000; // 100%

    uint256 internal maturityFuture;
    uint256 internal maturityPast;

    function setUp() public {
        vm.warp(1_000_000);
        maturityFuture = block.timestamp + 30 days;
        maturityPast = block.timestamp - 1;

        oracle = new MockLEOracle();
        ledger = new MockLELedger();
        centuari = new MockLECentuari(ledger);
        risk = new MockLERisk();

        LiquidationEngine impl = new LiquidationEngine();
        bytes memory initData = abi.encodeCall(
            LiquidationEngine.initialize,
            (owner, address(centuari), address(ledger), address(risk), address(oracle), BONUS, HF_CF, MAT_CF, pauser)
        );
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(impl), proxyAdmin, initData);
        engine = LiquidationEngine(address(proxy));

        // $1 prices, correct decimals.
        oracle.set(LOAN, 1e18, 18, true);
        oracle.set(COLL, 1e18, 18, true);
        oracle.set(COLL6, 1e18, 6, true);
    }

    function _mid(address loanToken, uint256 maturity) internal pure returns (bytes32) {
        return keccak256(abi.encode(loanToken, maturity));
    }

    function _fundLiquidatorLoan(uint256 amt) internal {
        ledger.setAvailable(liquidator, LOAN, amt);
    }

    function _setupHFPosition(address collateral, uint256 debtAmt, uint256 collAvail) internal returns (bytes32 mid) {
        mid = _mid(LOAN, maturityFuture);
        centuari.setDebt(mid, borrower, debtAmt);
        risk.setLiquidatable(borrower, true);
        ledger.setAvailable(borrower, collateral, collAvail);
        ledger.setUsed(borrower, collateral, true);
    }

    // ---- happy path: HF-triggered partial liquidation, exact 18-dec math ----

    function test_hfLiquidation_partial_exactMath() public {
        _setupHFPosition(COLL, 100e18, 100e18);
        _fundLiquidatorLoan(100e18);

        vm.prank(liquidator);
        (uint256 repaid, uint256 seized) = engine.liquidate(borrower, LOAN, maturityFuture, COLL, 100e18, 0);

        // 50% close factor → repay 50; 8% bonus → seize 54.
        assertEq(repaid, 50e18, "repaid");
        assertEq(seized, 54e18, "seized");
        assertEq(centuari.getBorrowPosition(_mid(LOAN, maturityFuture), borrower), 50e18, "debt");
        assertEq(ledger.available(liquidator, COLL), 54e18, "liquidator COLL");
        assertEq(ledger.available(borrower, COLL), 46e18, "borrower COLL");
        assertEq(ledger.available(liquidator, LOAN), 50e18, "liquidator LOAN debited");
        assertTrue(ledger.usedAsCollateral(borrower, COLL), "still flagged (not drained)");
    }

    // ---- decimals safety: 6-dec collateral ----

    function test_hfLiquidation_sixDecimalCollateral() public {
        bytes32 mid = _mid(LOAN, maturityFuture);
        centuari.setDebt(mid, borrower, 100e18);
        risk.setLiquidatable(borrower, true);
        ledger.setAvailable(borrower, COLL6, 100e6);
        ledger.setUsed(borrower, COLL6, true);
        _fundLiquidatorLoan(100e18);

        vm.prank(liquidator);
        (uint256 repaid, uint256 seized) = engine.liquidate(borrower, LOAN, maturityFuture, COLL6, 100e18, 0);

        // repay 50 (50%), seize $54 worth of a 6-dec $1 token = 54e6.
        assertEq(repaid, 50e18, "repaid");
        assertEq(seized, 54e6, "seized 6-dec");
        assertEq(ledger.available(liquidator, COLL6), 54e6, "liquidator COLL6");
    }

    // ---- requested amount below cap is honored ----

    function test_hfLiquidation_belowCloseFactor_usesRequested() public {
        _setupHFPosition(COLL, 100e18, 100e18);
        _fundLiquidatorLoan(100e18);

        vm.prank(liquidator);
        (uint256 repaid, uint256 seized) = engine.liquidate(borrower, LOAN, maturityFuture, COLL, 30e18, 0);

        assertEq(repaid, 30e18, "repaid requested");
        assertEq(seized, 30e18 + (30e18 * BONUS / 10000), "seized w/ bonus"); // 32.4e18
    }

    // ---- matured trigger works even when HF is healthy ----

    function test_maturedLiquidation_fullClose_ignoresHF() public {
        bytes32 mid = _mid(LOAN, maturityPast);
        centuari.setDebt(mid, borrower, 100e18);
        risk.setLiquidatable(borrower, false); // NOT HF-liquidatable
        ledger.setAvailable(borrower, COLL, 200e18);
        ledger.setUsed(borrower, COLL, true);
        _fundLiquidatorLoan(200e18);

        vm.prank(liquidator);
        (uint256 repaid, uint256 seized) = engine.liquidate(borrower, LOAN, maturityPast, COLL, 100e18, 0);

        // matured → 100% close factor; full debt repayable.
        assertEq(repaid, 100e18, "repaid full");
        assertEq(seized, 108e18, "seized w/ bonus");
        assertEq(centuari.getBorrowPosition(mid, borrower), 0, "debt cleared");
    }

    function test_notLiquidatable_reverts() public {
        bytes32 mid = _mid(LOAN, maturityFuture);
        centuari.setDebt(mid, borrower, 100e18);
        risk.setLiquidatable(borrower, false); // healthy + not matured
        ledger.setAvailable(borrower, COLL, 100e18);
        ledger.setUsed(borrower, COLL, true);
        _fundLiquidatorLoan(100e18);

        vm.prank(liquidator);
        vm.expectRevert(ILiquidationEngine.NotLiquidatable.selector);
        engine.liquidate(borrower, LOAN, maturityFuture, COLL, 10e18, 0);
    }

    // ---- bad debt: collateral exhausted, repay backed out, auto-unmark ----

    function test_badDebt_capsToAvailableCollateral_andUnmarks() public {
        _setupHFPosition(COLL, 100e18, 20e18); // only 20 COLL available
        _fundLiquidatorLoan(100e18);

        vm.prank(liquidator);
        (uint256 repaid, uint256 seized) = engine.liquidate(borrower, LOAN, maturityFuture, COLL, 50e18, 0);

        // Seize all 20 COLL; supportable repay = 20 / 1.08 = 18.518...
        assertEq(seized, 20e18, "seized all collateral");
        assertEq(repaid, Math.mulDiv(20e18, 10000, 10800), "repay backed out from collateral");
        assertEq(ledger.available(borrower, COLL), 0, "collateral drained");
        assertFalse(ledger.usedAsCollateral(borrower, COLL), "auto-unmarked when drained");
        assertGt(centuari.getBorrowPosition(_mid(LOAN, maturityFuture), borrower), 0, "residual bad debt");
    }

    function test_collateralNotFlagged_reverts() public {
        bytes32 mid = _mid(LOAN, maturityFuture);
        centuari.setDebt(mid, borrower, 100e18);
        risk.setLiquidatable(borrower, true);
        ledger.setAvailable(borrower, COLL, 100e18);
        ledger.setUsed(borrower, COLL, false); // NOT flagged
        _fundLiquidatorLoan(100e18);

        vm.prank(liquidator);
        vm.expectRevert(ILiquidationEngine.CollateralNotFlagged.selector);
        engine.liquidate(borrower, LOAN, maturityFuture, COLL, 10e18, 0);
    }

    function test_slippage_reverts() public {
        _setupHFPosition(COLL, 100e18, 100e18);
        _fundLiquidatorLoan(100e18);

        vm.prank(liquidator);
        vm.expectRevert(ILiquidationEngine.SlippageExceeded.selector);
        engine.liquidate(borrower, LOAN, maturityFuture, COLL, 50e18, 1000e18); // minOut too high
    }

    function test_noDebt_reverts() public {
        risk.setLiquidatable(borrower, true);
        ledger.setUsed(borrower, COLL, true);
        _fundLiquidatorLoan(100e18);

        vm.prank(liquidator);
        vm.expectRevert(ILiquidationEngine.NoDebt.selector);
        engine.liquidate(borrower, LOAN, maturityFuture, COLL, 10e18, 0);
    }

    function test_loanTokenUnpriced_reverts() public {
        _setupHFPosition(COLL, 100e18, 100e18);
        _fundLiquidatorLoan(100e18);
        oracle.set(LOAN, 1e18, 18, false); // loan token unpriced

        vm.prank(liquidator);
        vm.expectRevert(ILiquidationEngine.LoanTokenUnpriced.selector);
        engine.liquidate(borrower, LOAN, maturityFuture, COLL, 10e18, 0);
    }

    function test_paused_reverts() public {
        _setupHFPosition(COLL, 100e18, 100e18);
        _fundLiquidatorLoan(100e18);

        vm.prank(pauser);
        engine.pause();

        vm.prank(liquidator);
        vm.expectRevert(ILiquidationEngine.ContractPaused.selector);
        engine.liquidate(borrower, LOAN, maturityFuture, COLL, 10e18, 0);
    }

    function test_setters_onlyOwner_and_pause_onlyPauser() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        engine.setDefaultLiquidationBonus(500);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(ILiquidationEngine.Unauthorized.selector);
        engine.pause();

        vm.prank(owner);
        engine.setDefaultLiquidationBonus(500);
        assertEq(engine.defaultLiquidationBonusBps(), 500);
    }
}
