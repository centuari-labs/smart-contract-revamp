// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Centuari} from "../../src/core/centuari/Centuari.sol";
import {BalanceLedger} from "../../src/core/balance-ledger/BalanceLedger.sol";
import {RiskModule} from "../../src/core/risk/RiskModule.sol";
import {OracleRouter} from "../../src/core/oracle/OracleRouter.sol";
import {LiquidationEngine} from "../../src/core/liquidation/LiquidationEngine.sol";
import {ILiquidationEngine} from "../../src/interfaces/ILiquidationEngine.sol";
import {IBalanceLedger} from "../../src/interfaces/IBalanceLedger.sol";
import {IPriceFeed} from "../../src/interfaces/IPriceFeed.sol";
import {MockToken} from "../../src/mocks/MockToken.sol";

/// @notice Tiny IPriceFeed for the integration wiring: always-fresh (updatedAt =
///         block.timestamp), 1e18-scaled price set per test.
contract TestFeed is IPriceFeed {
    uint256 public price1e18;

    constructor(uint256 p) {
        price1e18 = p;
    }

    function set(uint256 p) external {
        price1e18 = p;
    }

    function latestPriceUsd() external view returns (uint256, uint256) {
        return (price1e18, block.timestamp);
    }
}

/// @title LiquidationEngineIntegrationTest
/// @notice End-to-end liquidation across the REAL Centuari + BalanceLedger +
///         RiskModule + OracleRouter + LiquidationEngine, with real MockToken
///         ERC20s (6-dec loan, 18-dec collateral) so the oracle decimal path and
///         the engine USD-to-base-unit inverse-probe are exercised for real.
contract LiquidationEngineIntegrationTest is Test {
    BalanceLedger internal ledger;
    Centuari internal centuari;
    RiskModule internal risk;
    OracleRouter internal router;
    LiquidationEngine internal engine;

    MockToken internal usdc; // loan token, 6 decimals
    MockToken internal weth; // collateral, 18 decimals
    TestFeed internal feedUsdc;
    TestFeed internal feedWeth;

    address internal owner = makeAddr("owner");
    address internal proxyAdmin = makeAddr("proxyAdmin");
    address internal settlement = makeAddr("settlement");
    address internal feeCollector = makeAddr("feeCollector");
    address internal seeder = makeAddr("seeder");
    address internal pauser = makeAddr("pauser");

    address internal lender = makeAddr("lender");
    address internal borrower = makeAddr("borrower");
    address internal liquidator = makeAddr("liquidator");

    uint256 internal constant BONUS = 800; // 8%
    uint256 internal constant LTV = 8000; // 80%

    function setUp() public {
        vm.warp(1_000_000);

        usdc = new MockToken("USD Coin", "USDC", 6, 0);
        weth = new MockToken("Wrapped Ether", "WETH", 18, 0);

        // BalanceLedger (proxy)
        BalanceLedger blImpl = new BalanceLedger();
        bytes memory blInit = abi.encodeCall(BalanceLedger.initialize, (owner, true));
        ledger = BalanceLedger(address(new TransparentUpgradeableProxy(address(blImpl), proxyAdmin, blInit)));

        // Centuari (proxy)
        Centuari cImpl = new Centuari();
        bytes memory cInit = abi.encodeCall(Centuari.initialize, (owner, settlement, address(ledger), feeCollector));
        centuari = Centuari(address(new TransparentUpgradeableProxy(address(cImpl), proxyAdmin, cInit)));

        // OracleRouter (proxy, owned by this test contract) + fresh feeds ($1 each)
        OracleRouter routerImpl = new OracleRouter();
        bytes memory rInitData = abi.encodeCall(OracleRouter.initialize, (address(this)));
        router = OracleRouter(address(new TransparentUpgradeableProxy(address(routerImpl), proxyAdmin, rInitData)));

        feedUsdc = new TestFeed(1e18);
        feedWeth = new TestFeed(1e18);
        router.setFeed(address(usdc), address(feedUsdc));
        router.setFeed(address(weth), address(feedWeth));
        router.setMaxStaleness(address(usdc), 365 days);
        router.setMaxStaleness(address(weth), 365 days);

        // RiskModule (proxy) wired to the real oracle + Centuari + ledger
        RiskModule rmImpl = new RiskModule();
        bytes memory rmInit =
            abi.encodeCall(RiskModule.initialize, (owner, address(router), address(centuari), address(ledger)));
        risk = RiskModule(address(new TransparentUpgradeableProxy(address(rmImpl), proxyAdmin, rmInit)));

        // LiquidationEngine (proxy)
        LiquidationEngine eImpl = new LiquidationEngine();
        bytes memory eInit = abi.encodeCall(
            LiquidationEngine.initialize,
            (owner, address(centuari), address(ledger), address(risk), address(router), BONUS, 5000, 10000, pauser)
        );
        engine = LiquidationEngine(address(new TransparentUpgradeableProxy(address(eImpl), proxyAdmin, eInit)));

        // Wiring (owner-gated)
        vm.startPrank(owner);
        ledger.forceAddWriter(address(centuari));
        ledger.forceAddWriter(address(engine));
        ledger.forceAddWriter(seeder);
        centuari.setLiquidationEngine(address(engine));
        risk.setDefaultBuffer(0); // clean HF math; isLiquidatable ignores buffer anyway
        risk.setLtv(address(weth), LTV);
        vm.stopPrank();
    }

    // ---- helpers ----

    function _seed(address user, address asset, uint256 amt) internal {
        vm.prank(seeder);
        ledger.credit(user, asset, amt);
    }

    /// @dev Settle a 0-rate, 0-fee match so debt == principal, with WETH flagged as
    ///      the borrower collateral. Returns the marketId.
    function _open(uint256 principal, uint256 maturity, uint256 collateralAmt) internal returns (bytes32 mid) {
        mid = centuari.getMarketId(address(usdc), maturity);
        _seed(lender, address(usdc), principal); // lender funds the loan
        _seed(borrower, address(weth), collateralAmt); // borrower collateral balance

        address[] memory coll = new address[](1);
        coll[0] = address(weth);

        vm.prank(settlement);
        centuari.settleMatch(mid, lender, borrower, address(usdc), principal, 0, maturity, true, 0, 0, 0, 0, coll);
    }

    // ---- HF-triggered partial liquidation, mixed decimals ----

    function test_hfLiquidation_endToEnd() public {
        uint256 maturity = block.timestamp + 30 days;
        bytes32 mid = _open(1000e6, maturity, 1100e18); // debt $1000, collateral $1100

        // HF = (1100-1000)*0.8/1000 = 0.08 < 1 -> liquidatable.
        assertTrue(risk.isLiquidatable(borrower), "should be HF-liquidatable");

        _seed(liquidator, address(usdc), 1000e6); // liquidator funds the repay

        vm.prank(liquidator);
        (uint256 repaid, uint256 seized) = engine.liquidate(borrower, address(usdc), maturity, address(weth), 1000e6, 0);

        // 50% close factor -> repay 500 USDC; 8% bonus -> seize $540 of WETH = 540e18.
        assertEq(repaid, 500e6, "repaid");
        assertEq(seized, 540e18, "seized w/ bonus");
        assertEq(centuari.getBorrowPosition(mid, borrower), 500e6, "debt halved");
        assertEq(ledger.available(liquidator, address(weth)), 540e18, "liquidator got collateral");
        assertEq(ledger.available(borrower, address(weth)), 560e18, "borrower collateral reduced");
        assertEq(ledger.available(liquidator, address(usdc)), 500e6, "liquidator loan debited");
        assertTrue(ledger.usedAsCollateral(borrower, address(weth)), "still flagged (not drained)");
    }

    // ---- matured/default liquidation works even when HF is healthy ----

    function test_maturedLiquidation_endToEnd() public {
        uint256 maturity = block.timestamp + 30 days;
        bytes32 mid = _open(1000e6, maturity, 3000e18); // debt $1000, collateral $3000 -> HF 1.6

        assertFalse(risk.isLiquidatable(borrower), "healthy before maturity");

        vm.warp(maturity + 1); // default

        _seed(liquidator, address(usdc), 1000e6);

        vm.prank(liquidator);
        (uint256 repaid, uint256 seized) = engine.liquidate(borrower, address(usdc), maturity, address(weth), 1000e6, 0);

        // matured -> 100% close factor; full debt repayable, 8% bonus.
        assertEq(repaid, 1000e6, "full repay");
        assertEq(seized, 1080e18, "seize w/ bonus");
        assertEq(centuari.getBorrowPosition(mid, borrower), 0, "debt cleared");
    }

    // ---- bad debt: collateral worth less than the seize, capped + auto-unmark ----

    function test_badDebt_endToEnd() public {
        uint256 maturity = block.timestamp + 30 days;
        bytes32 mid = _open(1000e6, maturity, 100e18); // collateral only $100 vs $1000 debt

        assertTrue(risk.isLiquidatable(borrower), "underwater -> liquidatable");

        _seed(liquidator, address(usdc), 1000e6);

        vm.prank(liquidator);
        (uint256 repaid, uint256 seized) = engine.liquidate(borrower, address(usdc), maturity, address(weth), 500e6, 0);

        // All 100 WETH seized; supportable repay = $100 / 1.08 = 92.59... USDC.
        assertEq(seized, 100e18, "seized all collateral");
        assertEq(repaid, Math.mulDiv(100e6, 10000, 10800), "repay backed out from capped collateral");
        assertEq(ledger.available(borrower, address(weth)), 0, "collateral drained");
        assertFalse(ledger.usedAsCollateral(borrower, address(weth)), "auto-unmarked when drained");
        assertGt(centuari.getBorrowPosition(mid, borrower), 0, "residual bad debt remains");
    }

    // ---- fail-closed: stale collateral price blocks HF liquidation ----

    function test_staleOracle_blocksHfLiquidation() public {
        uint256 maturity = block.timestamp + 30 days;
        _open(1000e6, maturity, 1100e18);
        assertTrue(risk.isLiquidatable(borrower));

        // Make WETH unpriced (price 0 -> router returns ok=false).
        feedWeth.set(0);
        assertFalse(risk.isLiquidatable(borrower), "fail-closed: not liquidatable when unpriced");

        _seed(liquidator, address(usdc), 1000e6);
        vm.prank(liquidator);
        vm.expectRevert(ILiquidationEngine.NotLiquidatable.selector);
        engine.liquidate(borrower, address(usdc), maturity, address(weth), 100e6, 0);
    }

    // ---- liquidator without loan-token balance cannot liquidate ----

    function test_liquidatorUnfunded_reverts() public {
        uint256 maturity = block.timestamp + 30 days;
        _open(1000e6, maturity, 1100e18);
        // liquidator NOT funded with USDC
        vm.prank(liquidator);
        vm.expectRevert(IBalanceLedger.InsufficientBalance.selector);
        engine.liquidate(borrower, address(usdc), maturity, address(weth), 500e6, 0);
    }
}
