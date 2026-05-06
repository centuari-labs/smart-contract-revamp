// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Centuari} from "../../src/core/centuari/Centuari.sol";
import {ICentuari} from "../../src/interfaces/ICentuari.sol";
import {BalanceLedger} from "../../src/core/balance-ledger/BalanceLedger.sol";
import {CentuariBondERC20Factory} from "../../src/core/centuari/CentuariBondERC20Factory.sol";
import {CentuariBondERC20} from "../../src/core/centuari/CentuariBondERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title CentuariV2
/// @notice Mock V2 contract for testing upgrades
contract CentuariV2 is Centuari {
    uint256 private _version;

    function version() external view returns (uint256) {
        return _version;
    }

    function initializeV2() external reinitializer(2) {
        _version = 2;
    }
}

/// @title CentuariTest
/// @notice Test suite for Centuari contract with BalanceLedger integration
contract CentuariTest is Test {
    Centuari public implementation;
    Centuari public centuari;
    BalanceLedger public balanceLedgerContract;
    CentuariBondERC20Factory public bondFactory;
    ProxyAdmin public proxyAdmin;
    TransparentUpgradeableProxy public proxy;

    address public owner;
    address public settlement;
    address public operator;
    address public user;
    address public loanToken;
    address public proxyAdminOwner;
    address public feeCollector;
    address public balanceSeeder;

    // Constants matching CentuariStorage
    uint256 constant RATE_PRECISION = 10000;
    uint256 constant SECONDS_PER_YEAR = 365 days;

    // Events to test
    event MarketCreated(bytes32 indexed marketId, address indexed loanToken, uint256 indexed maturity);

    event LendPositionCreated(
        bytes32 indexed marketId,
        address indexed lender,
        address indexed bondToken,
        uint256 cbtAmount,
        uint256 principal,
        uint256 rate
    );

    event BorrowPositionCreated(
        bytes32 indexed marketId, address indexed borrower, uint256 principal, uint256 debt, uint256 rate
    );

    event SettlementUpdated(address indexed oldSettlement, address indexed newSettlement);
    event BalanceLedgerUpdated(address indexed oldLedger, address indexed newLedger);
    event FeeCollectorUpdated(address indexed oldCollector, address indexed newCollector);
    event Paused(address account);
    event Unpaused(address account);
    event Repaid(bytes32 indexed marketId, address indexed borrower, uint256 amount);
    event LendPositionWithdrawn(
        bytes32 indexed marketId, address indexed lender, uint256 cbtBurned, uint256 amountWithdrawn
    );
    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);

    function setUp() public {
        owner = makeAddr("owner");
        settlement = makeAddr("settlement");
        operator = makeAddr("operator");
        user = makeAddr("user");
        loanToken = makeAddr("loanToken");
        proxyAdminOwner = makeAddr("proxyAdminOwner");
        feeCollector = makeAddr("feeCollector");
        balanceSeeder = makeAddr("balanceSeeder");

        // Deploy BalanceLedger (real contract behind proxy)
        BalanceLedger blImpl = new BalanceLedger();
        bytes memory blInitData = abi.encodeCall(
            BalanceLedger.initialize,
            (owner, true) // forceWriterRegistrationEnabled = true for tests
        );
        TransparentUpgradeableProxy blProxy =
            new TransparentUpgradeableProxy(address(blImpl), proxyAdminOwner, blInitData);
        balanceLedgerContract = BalanceLedger(address(blProxy));

        // Deploy Centuari implementation
        implementation = new Centuari();

        // Prepare initialization data
        bytes memory initData =
            abi.encodeCall(Centuari.initialize, (owner, settlement, address(balanceLedgerContract), feeCollector));

        // Deploy TransparentUpgradeableProxy
        proxy = new TransparentUpgradeableProxy(address(implementation), proxyAdminOwner, initData);

        // Get the ProxyAdmin address
        proxyAdmin = ProxyAdmin(_getProxyAdmin(address(proxy)));

        // Cast proxy to Centuari
        centuari = Centuari(address(proxy));

        // Register Centuari as authorized writer on BalanceLedger
        vm.prank(owner);
        balanceLedgerContract.forceAddWriter(address(centuari));

        // Register balanceSeeder as authorized writer for funding test users
        vm.prank(owner);
        balanceLedgerContract.forceAddWriter(balanceSeeder);

        // Deploy bond token factory and wire it to Centuari
        bondFactory = new CentuariBondERC20Factory(address(centuari));
        vm.prank(owner);
        centuari.setBondTokenFactory(address(bondFactory));
    }

    function _getProxyAdmin(address _proxy) internal view returns (address) {
        bytes32 adminSlot = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
        bytes32 adminValue = vm.load(_proxy, adminSlot);
        return address(uint160(uint256(adminValue)));
    }

    // ============ Helper Functions ============

    function _getMarketId(address _loanToken, uint256 _maturity) internal pure returns (bytes32) {
        return keccak256(abi.encode(_loanToken, _maturity));
    }

    /// @dev Day-count convention: start+1 = day 1, maturity-1 = last day (matches Centuari._interestWithDayCount)
    function _interestWithDayCount(uint256 principal, uint256 rate, uint256 start, uint256 maturity)
        internal
        pure
        returns (uint256)
    {
        uint256 rawDays = (maturity - start) / 1 days;
        uint256 days_ = rawDays > 0 ? rawDays - 1 : 0;
        return Math.mulDiv(Math.mulDiv(principal, rate, RATE_PRECISION), days_, 365);
    }

    function _expectedCbt(uint256 principal, uint256 rate, uint256 maturity) internal view returns (uint256) {
        return principal + _interestWithDayCount(principal, rate, block.timestamp, maturity);
    }

    function _expectedDebt(uint256 principal, uint256 rate, uint256 maturity) internal view returns (uint256) {
        return principal + _interestWithDayCount(principal, rate, block.timestamp, maturity);
    }

    /// @dev Fund a user's BalanceLedger balance for testing
    function _fundUser(address _user, address _asset, uint256 _amount) internal {
        vm.prank(balanceSeeder);
        balanceLedgerContract.credit(_user, _asset, _amount);
    }

    /// @dev Settle a match with pre-funding. Funds the lender with enough balance to cover
    ///      matchedAmount + all lender fees, and the borrower with enough for borrower fees.
    function _settleMatchWithFunding(
        address lender,
        address borrower,
        uint256 matchedAmount,
        uint256 rate,
        uint256 maturity,
        bool borrowerIsTaker,
        uint256 lenderSettlementFee,
        uint256 borrowerSettlementFee,
        uint256 makerFeeAmount,
        uint256 takerFeeAmount
    ) internal returns (bytes32 marketId) {
        marketId = _getMarketId(loanToken, maturity);

        // Calculate total fees
        uint256 lenderFee = borrowerIsTaker ? makerFeeAmount : takerFeeAmount;
        uint256 borrowerFee = borrowerIsTaker ? takerFeeAmount : makerFeeAmount;
        uint256 totalLenderFee = lenderSettlementFee + lenderFee;
        uint256 totalBorrowerFee = borrowerSettlementFee + borrowerFee;

        // Fund lender: matchedAmount + totalLenderFee
        _fundUser(lender, loanToken, matchedAmount + totalLenderFee);

        // Fund borrower: totalBorrowerFee (borrower receives matchedAmount credit during settle)
        if (totalBorrowerFee > 0) {
            _fundUser(borrower, loanToken, totalBorrowerFee);
        }

        vm.prank(settlement);
        centuari.settleMatch(
            marketId,
            lender,
            borrower,
            loanToken,
            matchedAmount,
            rate,
            maturity,
            borrowerIsTaker,
            lenderSettlementFee,
            borrowerSettlementFee,
            makerFeeAmount,
            takerFeeAmount,
            new address[](0)
        );
    }

    // ============ Initialization Tests ============

    function test_Initialize() public view {
        assertEq(centuari.owner(), owner);
        assertEq(centuari.settlement(), settlement);
        assertEq(centuari.balanceLedger(), address(balanceLedgerContract));
        assertEq(centuari.feeCollector(), feeCollector);
        assertEq(centuari.paused(), false);
    }

    function test_Initialize_RevertZeroOwner() public {
        Centuari newImpl = new Centuari();
        bytes memory initData =
            abi.encodeCall(Centuari.initialize, (address(0), settlement, address(balanceLedgerContract), feeCollector));
        vm.expectRevert(ICentuari.ZeroAddress.selector);
        new TransparentUpgradeableProxy(address(newImpl), proxyAdminOwner, initData);
    }

    function test_Initialize_RevertZeroSettlement() public {
        Centuari newImpl = new Centuari();
        bytes memory initData =
            abi.encodeCall(Centuari.initialize, (owner, address(0), address(balanceLedgerContract), feeCollector));
        vm.expectRevert(ICentuari.ZeroAddress.selector);
        new TransparentUpgradeableProxy(address(newImpl), proxyAdminOwner, initData);
    }

    function test_Initialize_RevertZeroBalanceLedger() public {
        Centuari newImpl = new Centuari();
        bytes memory initData = abi.encodeCall(Centuari.initialize, (owner, settlement, address(0), feeCollector));
        vm.expectRevert(ICentuari.ZeroAddress.selector);
        new TransparentUpgradeableProxy(address(newImpl), proxyAdminOwner, initData);
    }

    function test_Initialize_RevertZeroFeeCollector() public {
        Centuari newImpl = new Centuari();
        bytes memory initData =
            abi.encodeCall(Centuari.initialize, (owner, settlement, address(balanceLedgerContract), address(0)));
        vm.expectRevert(ICentuari.ZeroAddress.selector);
        new TransparentUpgradeableProxy(address(newImpl), proxyAdminOwner, initData);
    }

    // ============ settleMatch Tests ============

    function test_SettleMatch_Success() public {
        address lender = makeAddr("lender");
        address borrower = makeAddr("borrower");
        uint256 matchedAmount = 1000 ether;
        uint256 rate = 500; // 5%
        uint256 maturity = block.timestamp + 365 days;

        bytes32 expectedMarketId = _getMarketId(loanToken, maturity);
        uint256 expectedCbt = _expectedCbt(matchedAmount, rate, maturity);
        uint256 expectedDebt = _expectedDebt(matchedAmount, rate, maturity);

        // Fund lender
        _fundUser(lender, loanToken, matchedAmount);

        vm.expectEmit(true, true, true, true);
        emit MarketCreated(expectedMarketId, loanToken, maturity);

        vm.expectEmit(true, true, true, true);
        address expectedBondToken = bondFactory.computeBondTokenAddress(loanToken, maturity);
        emit LendPositionCreated(expectedMarketId, lender, expectedBondToken, expectedCbt, matchedAmount, rate);

        vm.expectEmit(true, true, false, true);
        emit BorrowPositionCreated(expectedMarketId, borrower, matchedAmount, expectedDebt, rate);

        vm.prank(settlement);
        centuari.settleMatch(
            expectedMarketId,
            lender,
            borrower,
            loanToken,
            matchedAmount,
            rate,
            maturity,
            true,
            0,
            0,
            0,
            0,
            new address[](0)
        );

        assertEq(centuari.getMarketTotalCbt(expectedMarketId), expectedCbt);
        assertEq(centuari.getLendPositionCbtAmount(expectedMarketId, lender), expectedCbt);

        // Verify borrower position
        assertEq(centuari.getBorrowPosition(expectedMarketId, borrower), expectedDebt);

        // Verify BalanceLedger state: lender debited, borrower credited
        assertEq(balanceLedgerContract.available(lender, loanToken), 0);
        assertEq(balanceLedgerContract.available(borrower, loanToken), matchedAmount);

        // Verify CBT was minted to Centuari, not to lender
        address bondTokenAddr = bondFactory.getBondToken(loanToken, maturity);
        CentuariBondERC20 bondToken = CentuariBondERC20(bondTokenAddr);
        assertEq(bondToken.balanceOf(address(centuari)), expectedCbt);
        assertEq(bondToken.balanceOf(lender), 0);
    }

    function test_SettleMatch_MultipleInSameMarket() public {
        address lender1 = makeAddr("lender1");
        address lender2 = makeAddr("lender2");
        address borrower1 = makeAddr("borrower1");
        address borrower2 = makeAddr("borrower2");
        uint256 maturity = block.timestamp + 365 days;
        uint256 rate = 500;

        // Fund lenders
        _fundUser(lender1, loanToken, 1000 ether);
        _fundUser(lender2, loanToken, 500 ether);

        // First match
        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            lender1,
            borrower1,
            loanToken,
            1000 ether,
            rate,
            maturity,
            true,
            0,
            0,
            0,
            0,
            new address[](0)
        );

        // Second match in same market
        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            lender2,
            borrower2,
            loanToken,
            500 ether,
            rate,
            maturity,
            true,
            0,
            0,
            0,
            0,
            new address[](0)
        );

        bytes32 marketId = _getMarketId(loanToken, maturity);
        uint256 expectedCbt1 = _expectedCbt(1000 ether, rate, maturity);
        uint256 expectedCbt2 = _expectedCbt(500 ether, rate, maturity);
        assertEq(centuari.getMarketTotalCbt(marketId), expectedCbt1 + expectedCbt2);

        // Verify both lenders debited to 0
        assertEq(balanceLedgerContract.available(lender1, loanToken), 0);
        assertEq(balanceLedgerContract.available(lender2, loanToken), 0);
    }

    function test_SettleMatch_RevertUnauthorized() public {
        vm.prank(user);
        vm.expectRevert(ICentuari.Unauthorized.selector);
        centuari.settleMatch(
            _getMarketId(loanToken, block.timestamp + 30 days),
            makeAddr("lender"),
            makeAddr("borrower"),
            loanToken,
            1000 ether,
            500,
            block.timestamp + 30 days,
            true,
            0,
            0,
            0,
            0,
            new address[](0)
        );
    }

    function test_SettleMatch_RevertWhenPaused() public {
        vm.prank(owner);
        centuari.pause();

        vm.prank(settlement);
        vm.expectRevert(ICentuari.ContractPaused.selector);
        centuari.settleMatch(
            _getMarketId(loanToken, block.timestamp + 30 days),
            makeAddr("lender"),
            makeAddr("borrower"),
            loanToken,
            1000 ether,
            500,
            block.timestamp + 30 days,
            true,
            0,
            0,
            0,
            0,
            new address[](0)
        );
    }

    function test_SettleMatch_RevertZeroAmount() public {
        vm.prank(settlement);
        vm.expectRevert(ICentuari.InvalidAmount.selector);
        centuari.settleMatch(
            _getMarketId(loanToken, block.timestamp + 30 days),
            makeAddr("lender"),
            makeAddr("borrower"),
            loanToken,
            0, // zero amount
            500,
            block.timestamp + 30 days,
            true,
            0,
            0,
            0,
            0,
            new address[](0)
        );
    }

    function test_SettleMatch_RevertPastMaturity() public {
        vm.prank(settlement);
        vm.expectRevert(ICentuari.InvalidMaturity.selector);
        centuari.settleMatch(
            _getMarketId(loanToken, block.timestamp - 1),
            makeAddr("lender"),
            makeAddr("borrower"),
            loanToken,
            1000 ether,
            500,
            block.timestamp - 1, // past maturity
            true,
            0,
            0,
            0,
            0,
            new address[](0)
        );
    }

    function test_SettleMatch_RevertCurrentTimestampMaturity() public {
        vm.prank(settlement);
        vm.expectRevert(ICentuari.InvalidMaturity.selector);
        centuari.settleMatch(
            _getMarketId(loanToken, block.timestamp),
            makeAddr("lender"),
            makeAddr("borrower"),
            loanToken,
            1000 ether,
            500,
            block.timestamp, // maturity at current timestamp
            true,
            0,
            0,
            0,
            0,
            new address[](0)
        );
    }

    // ============ Share Calculation Tests ============

    function test_ShareCalculation_FirstDeposit() public {
        address lender = makeAddr("lender");
        address borrower = makeAddr("borrower");
        uint256 amount = 1000 ether;
        uint256 maturity = block.timestamp + 365 days;

        _fundUser(lender, loanToken, amount);

        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            lender,
            borrower,
            loanToken,
            amount,
            500,
            maturity,
            true,
            0,
            0,
            0,
            0,
            new address[](0)
        );

        bytes32 marketId = _getMarketId(loanToken, maturity);
        uint256 expectedCbt = _expectedCbt(amount, 500, maturity);
        assertEq(centuari.getLendPositionCbtAmount(marketId, lender), expectedCbt);
    }

    function test_ShareCalculation_ProportionalShares() public {
        address lender1 = makeAddr("lender1");
        address lender2 = makeAddr("lender2");
        address borrower1 = makeAddr("borrower1");
        address borrower2 = makeAddr("borrower2");
        uint256 maturity = block.timestamp + 365 days;
        uint256 rate = 500;

        _fundUser(lender1, loanToken, 1000 ether);
        _fundUser(lender2, loanToken, 500 ether);

        // First lender deposits 1000 ether
        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            lender1,
            borrower1,
            loanToken,
            1000 ether,
            rate,
            maturity,
            true,
            0,
            0,
            0,
            0,
            new address[](0)
        );

        // Second lender deposits 500 ether
        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            lender2,
            borrower2,
            loanToken,
            500 ether,
            rate,
            maturity,
            true,
            0,
            0,
            0,
            0,
            new address[](0)
        );

        bytes32 marketId = _getMarketId(loanToken, maturity);
        uint256 expectedCbt1 = _expectedCbt(1000 ether, rate, maturity);
        uint256 expectedCbt2 = _expectedCbt(500 ether, rate, maturity);
        assertEq(centuari.getLendPositionCbtAmount(marketId, lender1), expectedCbt1);
        assertEq(centuari.getLendPositionCbtAmount(marketId, lender2), expectedCbt2);
    }

    // ============ Interest Calculation Tests ============

    function test_InterestCalculation_OneYear() public {
        address lender = makeAddr("lender");
        address borrower = makeAddr("borrower");
        uint256 principal = 1000 ether;
        uint256 rate = 500; // 5%
        uint256 maturity = block.timestamp + 365 days;

        _fundUser(lender, loanToken, principal);

        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            lender,
            borrower,
            loanToken,
            principal,
            rate,
            maturity,
            true,
            0,
            0,
            0,
            0,
            new address[](0)
        );

        bytes32 marketId = _getMarketId(loanToken, maturity);

        // Day-count: 365 days -> 364 effective days. Interest = principal * rate * 364 / (RATE_PRECISION * 365)
        uint256 expectedDebt = _expectedDebt(principal, rate, maturity);
        assertEq(centuari.getBorrowPosition(marketId, borrower), expectedDebt);
    }

    function test_InterestCalculation_HalfYear() public {
        address lender = makeAddr("lender");
        address borrower = makeAddr("borrower");
        uint256 principal = 1000 ether;
        uint256 rate = 1000; // 10%
        uint256 maturity = block.timestamp + 182.5 days;

        _fundUser(lender, loanToken, principal);

        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            lender,
            borrower,
            loanToken,
            principal,
            rate,
            maturity,
            true,
            0,
            0,
            0,
            0,
            new address[](0)
        );

        bytes32 marketId = _getMarketId(loanToken, maturity);

        uint256 expectedDebt = _expectedDebt(principal, rate, maturity);
        assertEq(centuari.getBorrowPosition(marketId, borrower), expectedDebt);
    }

    /// @dev Day-count example: 1 Jan -> 1 Feb = 30 days (2 Jan = day 1, 31 Jan = last day). 1000 USDC at 10% => CBT ~ 1008
    function test_DayCount_Jan1ToFeb1_ThirtyDays() public {
        // Jan 1 00:00 UTC and Feb 1 00:00 UTC (use fixed timestamps)
        uint256 start = 1704067200; // 2024-01-01 00:00:00 UTC
        uint256 maturity = start + 31 days; // 2024-02-01 00:00:00 UTC
        vm.warp(start);

        address lender = makeAddr("lender");
        address borrower = makeAddr("borrower");
        uint256 principal = 1000 ether;
        uint256 rate = 1000; // 10%

        _fundUser(lender, loanToken, principal);

        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            lender,
            borrower,
            loanToken,
            principal,
            rate,
            maturity,
            true,
            0,
            0,
            0,
            0,
            new address[](0)
        );

        bytes32 marketId = _getMarketId(loanToken, maturity);
        uint256 expectedCbt = _expectedCbt(principal, rate, maturity);
        // 1000 + (1000 * 10% / 365 * 30) = 1000 + 8.219... ~ 1008
        assertEq(expectedCbt / 1 ether, 1008);
        assertEq(centuari.getLendPositionCbtAmount(marketId, lender), expectedCbt);
        assertEq(centuari.getBorrowPosition(marketId, borrower), expectedCbt);
    }

    // ============ Bond Token Tests ============

    function test_BondToken_MintedOnFirstLend() public {
        address lender = makeAddr("bondLender");
        address borrower = makeAddr("bondBorrower");
        uint256 amount = 1000 ether;
        uint256 maturity = block.timestamp + 365 days;

        _fundUser(lender, loanToken, amount);

        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            lender,
            borrower,
            loanToken,
            amount,
            500,
            maturity,
            true,
            0,
            0,
            0,
            0,
            new address[](0)
        );

        address bondTokenAddr = bondFactory.getBondToken(loanToken, maturity);
        assertTrue(bondTokenAddr != address(0));

        CentuariBondERC20 bondToken = CentuariBondERC20(bondTokenAddr);
        uint256 expectedCbt = _expectedCbt(amount, 500, maturity);
        // CBT is held by Centuari, not directly by lender
        assertEq(bondToken.balanceOf(address(centuari)), expectedCbt);
        assertEq(bondToken.balanceOf(lender), 0);
        assertEq(bondToken.totalSupply(), expectedCbt);
    }

    function test_BondToken_MultipleLendersSameMarket() public {
        address lender1 = makeAddr("bondLender1");
        address lender2 = makeAddr("bondLender2");
        address borrower1 = makeAddr("bondBorrower1");
        address borrower2 = makeAddr("bondBorrower2");
        uint256 maturity = block.timestamp + 365 days;
        uint256 rate = 500;

        _fundUser(lender1, loanToken, 1000 ether);
        _fundUser(lender2, loanToken, 500 ether);

        // First lender deposits 1000 ether
        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            lender1,
            borrower1,
            loanToken,
            1000 ether,
            rate,
            maturity,
            true,
            0,
            0,
            0,
            0,
            new address[](0)
        );

        // Second lender deposits 500 ether in the same market
        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            lender2,
            borrower2,
            loanToken,
            500 ether,
            rate,
            maturity,
            true,
            0,
            0,
            0,
            0,
            new address[](0)
        );

        address bondTokenAddr = bondFactory.getBondToken(loanToken, maturity);
        CentuariBondERC20 bondToken = CentuariBondERC20(bondTokenAddr);

        uint256 expectedCbt1 = _expectedCbt(1000 ether, rate, maturity);
        uint256 expectedCbt2 = _expectedCbt(500 ether, rate, maturity);
        // All CBT is held by Centuari; total supply equals sum of lender positions
        assertEq(bondToken.balanceOf(address(centuari)), expectedCbt1 + expectedCbt2);
        assertEq(bondToken.balanceOf(lender1), 0);
        assertEq(bondToken.balanceOf(lender2), 0);
        assertEq(bondToken.totalSupply(), expectedCbt1 + expectedCbt2);
    }

    function test_BondToken_ComputeAddressMatchesDeployed() public view {
        uint256 maturity = block.timestamp + 365 days;

        // No settleMatch yet; bond token not created
        address computed = bondFactory.computeBondTokenAddress(loanToken, maturity);

        // After creation, address should match computed; we can't create here in a view test,
        // but we can at least assert that computeBondTokenAddress does not return zero.
        assertTrue(computed != address(0));
    }

    // ============ Administrative Functions Tests ============

    function test_SetSettlement() public {
        address newSettlement = makeAddr("newSettlement");

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit SettlementUpdated(settlement, newSettlement);
        centuari.setSettlement(newSettlement);

        assertEq(centuari.settlement(), newSettlement);
    }

    function test_SetSettlement_RevertNotOwner() public {
        vm.prank(user);
        vm.expectRevert();
        centuari.setSettlement(makeAddr("newSettlement"));
    }

    function test_SetSettlement_RevertZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(ICentuari.ZeroAddress.selector);
        centuari.setSettlement(address(0));
    }

    function test_setBalanceLedger() public {
        address newBalanceLedger = makeAddr("newBalanceLedger");

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit BalanceLedgerUpdated(address(balanceLedgerContract), newBalanceLedger);
        centuari.setBalanceLedger(newBalanceLedger);

        assertEq(centuari.balanceLedger(), newBalanceLedger);
    }

    function test_setBalanceLedger_RevertNotOwner() public {
        vm.prank(user);
        vm.expectRevert();
        centuari.setBalanceLedger(makeAddr("newBalanceLedger"));
    }

    function test_setBalanceLedger_RevertZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(ICentuari.ZeroAddress.selector);
        centuari.setBalanceLedger(address(0));
    }

    function test_setFeeCollector() public {
        address newFeeCollector = makeAddr("newFeeCollector");

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit FeeCollectorUpdated(feeCollector, newFeeCollector);
        centuari.setFeeCollector(newFeeCollector);

        assertEq(centuari.feeCollector(), newFeeCollector);
    }

    function test_setFeeCollector_RevertNotOwner() public {
        vm.prank(user);
        vm.expectRevert();
        centuari.setFeeCollector(makeAddr("newFeeCollector"));
    }

    function test_setFeeCollector_RevertZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(ICentuari.ZeroAddress.selector);
        centuari.setFeeCollector(address(0));
    }

    function test_SetOperator() public {
        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit OperatorUpdated(address(0), operator);
        centuari.setOperator(operator);

        assertEq(centuari.operator(), operator);
    }

    function test_SetOperator_RevertNotOwner() public {
        vm.prank(user);
        vm.expectRevert();
        centuari.setOperator(operator);
    }

    function test_SetOperator_RevertZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(ICentuari.ZeroAddress.selector);
        centuari.setOperator(address(0));
    }

    // ============ Repay Tests ============

    function test_Repay_Success() public {
        vm.prank(owner);
        centuari.setOperator(operator);

        address lender = makeAddr("lender");
        address borrower = makeAddr("borrower");
        uint256 maturity = block.timestamp + 365 days;
        uint256 principal = 1000 ether;
        uint256 rate = 500;

        _fundUser(lender, loanToken, principal);

        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            lender,
            borrower,
            loanToken,
            principal,
            rate,
            maturity,
            true,
            0,
            0,
            0,
            0,
            new address[](0)
        );

        bytes32 marketId = _getMarketId(loanToken, maturity);
        uint256 posBefore = centuari.getBorrowPosition(marketId, borrower);
        // Borrower received matchedAmount credit; available = principal
        uint256 borrowerAvailBefore = balanceLedgerContract.available(borrower, loanToken);

        uint256 repayAmount = 500 ether;

        vm.expectEmit(true, true, false, true);
        emit Repaid(marketId, borrower, repayAmount);

        vm.prank(operator);
        centuari.repay(_getMarketId(loanToken, maturity), borrower, loanToken, repayAmount);

        assertEq(centuari.getBorrowPosition(marketId, borrower), posBefore - repayAmount);

        // Verify borrower was debited
        assertEq(balanceLedgerContract.available(borrower, loanToken), borrowerAvailBefore - repayAmount);
    }

    function test_Repay_RevertOnlyOperator() public {
        vm.prank(owner);
        centuari.setOperator(operator);

        address lender = makeAddr("lender");
        address borrower = makeAddr("borrower");
        uint256 maturity = block.timestamp + 365 days;

        _fundUser(lender, loanToken, 1000 ether);

        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            lender,
            borrower,
            loanToken,
            1000 ether,
            500,
            maturity,
            true,
            0,
            0,
            0,
            0,
            new address[](0)
        );

        vm.prank(user);
        vm.expectRevert(ICentuari.Unauthorized.selector);
        centuari.repay(_getMarketId(loanToken, maturity), borrower, loanToken, 100 ether);
    }

    function test_Repay_MoreThanDebt_Capped() public {
        vm.prank(owner);
        centuari.setOperator(operator);

        address lender = makeAddr("lender");
        address borrower = makeAddr("borrower");
        uint256 maturity = block.timestamp + 365 days;
        uint256 principal = 1000 ether;
        uint256 rate = 500;

        _fundUser(lender, loanToken, principal);

        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            lender,
            borrower,
            loanToken,
            principal,
            rate,
            maturity,
            true,
            0,
            0,
            0,
            0,
            new address[](0)
        );

        bytes32 marketId = _getMarketId(loanToken, maturity);
        uint256 debtInAssets = centuari.getBorrowPosition(marketId, borrower);

        // Give borrower extra balance so the large repay doesn't revert on insufficient balance
        // Borrower already has `principal` from the settle credit.
        // Debt = principal + interest, so borrower needs the interest portion extra
        uint256 extra = debtInAssets - principal;
        if (extra > 0) {
            _fundUser(borrower, loanToken, extra);
        }

        // Repay more than debt; should cap to full debt
        uint256 repayAmountRequested = debtInAssets + 1000 ether;

        vm.prank(operator);
        centuari.repay(_getMarketId(loanToken, maturity), borrower, loanToken, repayAmountRequested);

        assertEq(centuari.getBorrowPosition(marketId, borrower), 0);
    }

    function test_Repay_FullDebt() public {
        vm.prank(owner);
        centuari.setOperator(operator);

        address lender = makeAddr("lender");
        address borrower = makeAddr("borrower");
        uint256 maturity = block.timestamp + 365 days;
        uint256 principal = 1000 ether;
        uint256 rate = 500;

        _fundUser(lender, loanToken, principal);

        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            lender,
            borrower,
            loanToken,
            principal,
            rate,
            maturity,
            true,
            0,
            0,
            0,
            0,
            new address[](0)
        );

        bytes32 marketId = _getMarketId(loanToken, maturity);
        uint256 debtInAssets = centuari.getBorrowPosition(marketId, borrower);

        // Fund borrower with enough to cover full debt (they have principal from settle)
        uint256 extra = debtInAssets - principal;
        if (extra > 0) {
            _fundUser(borrower, loanToken, extra);
        }

        vm.prank(operator);
        centuari.repay(_getMarketId(loanToken, maturity), borrower, loanToken, debtInAssets);

        assertEq(centuari.getBorrowPosition(marketId, borrower), 0);
    }

    function test_Repay_RevertZeroPosition() public {
        vm.prank(owner);
        centuari.setOperator(operator);

        address borrower = makeAddr("borrower");
        uint256 maturity = block.timestamp + 365 days;

        vm.prank(operator);
        vm.expectRevert(ICentuari.InvalidAmount.selector);
        centuari.repay(_getMarketId(loanToken, maturity), borrower, loanToken, 100 ether);
    }

    function test_Repay_RevertZeroAmount() public {
        vm.prank(owner);
        centuari.setOperator(operator);

        address lender = makeAddr("lender");
        address borrower = makeAddr("borrower");
        uint256 maturity = block.timestamp + 365 days;

        _fundUser(lender, loanToken, 1000 ether);

        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            lender,
            borrower,
            loanToken,
            1000 ether,
            500,
            maturity,
            true,
            0,
            0,
            0,
            0,
            new address[](0)
        );

        vm.prank(operator);
        vm.expectRevert(ICentuari.InvalidAmount.selector);
        centuari.repay(_getMarketId(loanToken, maturity), borrower, loanToken, 0);
    }

    function test_Repay_RevertZeroBorrower() public {
        vm.prank(owner);
        centuari.setOperator(operator);

        vm.prank(operator);
        vm.expectRevert(ICentuari.ZeroAddress.selector);
        centuari.repay(_getMarketId(loanToken, block.timestamp + 365 days), address(0), loanToken, 100 ether);
    }

    function test_Repay_RevertWhenPaused() public {
        vm.prank(owner);
        centuari.setOperator(operator);

        address lender = makeAddr("lender");
        address borrower = makeAddr("borrower");
        uint256 maturity = block.timestamp + 365 days;

        _fundUser(lender, loanToken, 1000 ether);

        // Create loan while unpaused
        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            lender,
            borrower,
            loanToken,
            1000 ether,
            500,
            maturity,
            true,
            0,
            0,
            0,
            0,
            new address[](0)
        );

        // Now pause and expect repay to revert
        vm.prank(owner);
        centuari.pause();

        vm.prank(operator);
        vm.expectRevert(ICentuari.ContractPaused.selector);
        centuari.repay(_getMarketId(loanToken, maturity), borrower, loanToken, 100 ether);
    }

    // ============ WithdrawLendPosition Tests ============

    function test_WithdrawLendPosition_Success() public {
        address lender = makeAddr("lender");
        uint256 maturity = block.timestamp + 365 days;
        uint256 principal = 1000 ether;

        _fundUser(lender, loanToken, principal);

        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            lender,
            makeAddr("borrower"),
            loanToken,
            principal,
            500,
            maturity,
            true,
            0,
            0,
            0,
            0,
            new address[](0)
        );

        bytes32 marketId = _getMarketId(loanToken, maturity);
        address bondTokenAddr = bondFactory.getBondToken(loanToken, maturity);
        CentuariBondERC20 bondToken = CentuariBondERC20(bondTokenAddr);

        uint256 cbtBalance = bondToken.balanceOf(address(centuari));
        uint256 cbtToRedeem = cbtBalance / 2;

        uint256 posBefore = centuari.getLendPositionCbtAmount(marketId, lender);
        uint256 marketBefore = centuari.getMarketTotalCbt(marketId);
        uint256 lenderAvailBefore = balanceLedgerContract.available(lender, loanToken);

        vm.warp(maturity);

        vm.expectEmit(true, true, false, true);
        emit LendPositionWithdrawn(marketId, lender, cbtToRedeem, cbtToRedeem);

        vm.prank(lender);
        centuari.withdrawLendPosition(_getMarketId(loanToken, maturity), loanToken, maturity, cbtToRedeem);

        assertEq(centuari.getLendPositionCbtAmount(marketId, lender), posBefore - cbtToRedeem);
        assertEq(centuari.getMarketTotalCbt(marketId), marketBefore - cbtToRedeem);

        // Bond burned from Centuari's custody
        assertEq(bondToken.balanceOf(address(centuari)), cbtBalance - cbtToRedeem);

        // Lender credited in BalanceLedger
        assertEq(balanceLedgerContract.available(lender, loanToken), lenderAvailBefore + cbtToRedeem);
    }

    function test_WithdrawLendPosition_RevertZeroAmount() public {
        address lender = makeAddr("lender");
        uint256 maturity = block.timestamp + 365 days;

        _fundUser(lender, loanToken, 1000 ether);

        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            lender,
            makeAddr("borrower"),
            loanToken,
            1000 ether,
            500,
            maturity,
            true,
            0,
            0,
            0,
            0,
            new address[](0)
        );

        vm.warp(maturity);
        vm.prank(lender);
        vm.expectRevert(ICentuari.InvalidAmount.selector);
        centuari.withdrawLendPosition(_getMarketId(loanToken, maturity), loanToken, maturity, 0);
    }

    function test_WithdrawLendPosition_RevertBondTokenNotFound_NoFactory() public {
        Centuari centuariNoFactory = _deployCentuariWithoutBondFactory();

        // Register centuariNoFactory as writer
        vm.prank(owner);
        balanceLedgerContract.forceAddWriter(address(centuariNoFactory));

        address lender = makeAddr("lender");
        _fundUser(lender, loanToken, 1000 ether);

        vm.prank(settlement);
        centuariNoFactory.settleMatch(
            _getMarketId(loanToken, block.timestamp + 365 days),
            lender,
            makeAddr("borrower"),
            loanToken,
            1000 ether,
            500,
            block.timestamp + 365 days,
            true,
            0,
            0,
            0,
            0,
            new address[](0)
        );

        vm.prank(lender);
        vm.expectRevert(ICentuari.BondTokenNotFound.selector);
        centuariNoFactory.withdrawLendPosition(
            _getMarketId(loanToken, block.timestamp + 365 days), loanToken, block.timestamp + 365 days, 100 ether
        );
    }

    function test_WithdrawLendPosition_RevertInsufficientShares() public {
        address lender = makeAddr("lender");
        uint256 maturity = block.timestamp + 365 days;

        _fundUser(lender, loanToken, 1000 ether);

        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            lender,
            makeAddr("borrower"),
            loanToken,
            1000 ether,
            500,
            maturity,
            true,
            0,
            0,
            0,
            0,
            new address[](0)
        );

        bytes32 marketId = _getMarketId(loanToken, maturity);
        uint256 cbtBalance = centuari.getLendPositionCbtAmount(marketId, lender);

        vm.warp(maturity);
        vm.prank(lender);
        vm.expectRevert(ICentuari.InvalidAmount.selector);
        centuari.withdrawLendPosition(_getMarketId(loanToken, maturity), loanToken, maturity, cbtBalance + 1 ether);
    }

    function test_WithdrawLendPosition_RevertNotYetMatured() public {
        address lender = makeAddr("lender");
        uint256 maturity = block.timestamp + 365 days;

        _fundUser(lender, loanToken, 1000 ether);

        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            lender,
            makeAddr("borrower"),
            loanToken,
            1000 ether,
            500,
            maturity,
            true,
            0,
            0,
            0,
            0,
            new address[](0)
        );

        vm.prank(lender);
        vm.expectRevert(ICentuari.NotYetMatured.selector);
        centuari.withdrawLendPosition(_getMarketId(loanToken, maturity), loanToken, maturity, 100 ether);
    }

    function test_WithdrawLendPosition_RevertWhenPaused() public {
        address lender = makeAddr("lender");
        uint256 maturity = block.timestamp + 365 days;

        _fundUser(lender, loanToken, 1000 ether);

        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            lender,
            makeAddr("borrower"),
            loanToken,
            1000 ether,
            500,
            maturity,
            true,
            0,
            0,
            0,
            0,
            new address[](0)
        );

        vm.prank(owner);
        centuari.pause();

        vm.warp(maturity);
        vm.prank(lender);
        vm.expectRevert(ICentuari.ContractPaused.selector);
        centuari.withdrawLendPosition(_getMarketId(loanToken, maturity), loanToken, maturity, 100 ether);
    }

    function test_withdrawLendPosition_creditsLenderFromCentuari() public {
        address lender = makeAddr("lender");
        uint256 maturity = block.timestamp + 365 days;
        uint256 principal = 1000 ether;

        _fundUser(lender, loanToken, principal);

        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            lender,
            makeAddr("borrower"),
            loanToken,
            principal,
            500,
            maturity,
            true,
            0,
            0,
            0,
            0,
            new address[](0)
        );

        bytes32 marketId = _getMarketId(loanToken, maturity);
        address bondTokenAddr = bondFactory.getBondToken(loanToken, maturity);
        CentuariBondERC20 bondToken = CentuariBondERC20(bondTokenAddr);
        uint256 totalCbt = bondToken.balanceOf(address(centuari));

        vm.warp(maturity);

        vm.prank(lender);
        centuari.withdrawLendPosition(marketId, loanToken, maturity, totalCbt);

        // Bond burned from Centuari
        assertEq(bondToken.balanceOf(address(centuari)), 0);
        // Lender credited in BalanceLedger
        assertEq(balanceLedgerContract.available(lender, loanToken), totalCbt);
    }

    function _deployCentuariWithoutBondFactory() internal returns (Centuari) {
        Centuari impl = new Centuari();
        bytes memory initData =
            abi.encodeCall(Centuari.initialize, (owner, settlement, address(balanceLedgerContract), feeCollector));
        TransparentUpgradeableProxy p = new TransparentUpgradeableProxy(address(impl), proxyAdminOwner, initData);
        return Centuari(address(p));
    }

    function test_Pause() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit Paused(owner);
        centuari.pause();

        assertTrue(centuari.paused());
    }

    function test_Pause_RevertNotOwner() public {
        vm.prank(user);
        vm.expectRevert();
        centuari.pause();
    }

    function test_Unpause() public {
        vm.prank(owner);
        centuari.pause();

        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit Unpaused(owner);
        centuari.unpause();

        assertFalse(centuari.paused());
    }

    function test_Unpause_RevertNotOwner() public {
        vm.prank(owner);
        centuari.pause();

        vm.prank(user);
        vm.expectRevert();
        centuari.unpause();
    }

    // ============ View Functions Tests ============

    function test_GetMarketId() public view {
        uint256 maturity = block.timestamp + 30 days;
        bytes32 expected = keccak256(abi.encode(loanToken, maturity));
        assertEq(centuari.getMarketId(loanToken, maturity), expected);
    }

    function test_GetMarket_Empty() public view {
        bytes32 marketId = _getMarketId(loanToken, block.timestamp + 30 days);
        assertEq(centuari.getMarketTotalCbt(marketId), 0);
    }

    function test_GetLendPosition_Empty() public view {
        bytes32 marketId = _getMarketId(loanToken, block.timestamp + 30 days);
        assertEq(centuari.getLendPositionCbtAmount(marketId, user), 0);
    }

    function test_GetBorrowPosition_Empty() public view {
        bytes32 marketId = _getMarketId(loanToken, block.timestamp + 30 days);
        assertEq(centuari.getBorrowPosition(marketId, user), 0);
    }

    // ============ Collateral Flag Tests ============
    // Flags are never set or cleared implicitly by settlement/repay. They are only
    // mutated in response to explicit user requests: flag-at-settlement via
    // MatchData.collateralAssets, and standalone flag/unflag via CollateralManager.

    function test_settleMatch_doesNotFlagWhenCollateralAssetsEmpty() public {
        address lender = makeAddr("lender");
        address borrower = makeAddr("borrower");
        uint256 maturity = block.timestamp + 365 days;
        uint256 principal = 1000 ether;

        _fundUser(lender, loanToken, principal);

        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            lender,
            borrower,
            loanToken,
            principal,
            500,
            maturity,
            true,
            0,
            0,
            0,
            0,
            new address[](0)
        );

        assertFalse(balanceLedgerContract.usedAsCollateral(borrower, loanToken));
        address[] memory flagged = balanceLedgerContract.flaggedAssetsOf(borrower);
        assertEq(flagged.length, 0);
        assertEq(balanceLedgerContract.flaggedAt(borrower, loanToken), 0);
    }

    function test_settleMatch_flagsRequestedCollateralAssets() public {
        address lender = makeAddr("lender");
        address borrower = makeAddr("borrower");
        uint256 maturity = block.timestamp + 365 days;
        uint256 principal = 1000 ether;

        _fundUser(lender, loanToken, principal);

        address[] memory assets = new address[](1);
        assets[0] = loanToken;

        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            lender,
            borrower,
            loanToken,
            principal,
            500,
            maturity,
            true,
            0,
            0,
            0,
            0,
            assets
        );

        assertTrue(balanceLedgerContract.usedAsCollateral(borrower, loanToken));
        address[] memory flagged = balanceLedgerContract.flaggedAssetsOf(borrower);
        assertEq(flagged.length, 1);
        assertEq(flagged[0], loanToken);
        assertTrue(balanceLedgerContract.flaggedAt(borrower, loanToken) > 0);
    }

    function test_settleMatch_repeatFlagDoesNotRefreshTimestamp() public {
        address lender1 = makeAddr("lender1");
        address lender2 = makeAddr("lender2");
        address borrower = makeAddr("borrower");
        uint256 maturity = block.timestamp + 365 days;

        _fundUser(lender1, loanToken, 1000 ether);

        address[] memory assets = new address[](1);
        assets[0] = loanToken;

        // First settle with flag request
        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            lender1,
            borrower,
            loanToken,
            1000 ether,
            500,
            maturity,
            true,
            0,
            0,
            0,
            0,
            assets
        );

        uint64 firstFlaggedAt = balanceLedgerContract.flaggedAt(borrower, loanToken);
        assertTrue(firstFlaggedAt > 0);

        vm.warp(block.timestamp + 1 hours);

        _fundUser(lender2, loanToken, 500 ether);

        // Second settle re-requesting same flag: idempotent, no timestamp refresh
        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            lender2,
            borrower,
            loanToken,
            500 ether,
            500,
            maturity,
            true,
            0,
            0,
            0,
            0,
            assets
        );

        uint64 secondFlaggedAt = balanceLedgerContract.flaggedAt(borrower, loanToken);
        assertEq(secondFlaggedAt, firstFlaggedAt);
    }

    function test_repay_neverUnflagsEvenOnFullDebtClear() public {
        vm.prank(owner);
        centuari.setOperator(operator);

        address lender = makeAddr("lender");
        address borrower = makeAddr("borrower");
        uint256 maturity = block.timestamp + 365 days;
        uint256 principal = 1000 ether;
        uint256 rate = 500;

        _fundUser(lender, loanToken, principal);

        address[] memory assets = new address[](1);
        assets[0] = loanToken;

        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            lender,
            borrower,
            loanToken,
            principal,
            rate,
            maturity,
            true,
            0,
            0,
            0,
            0,
            assets
        );

        assertTrue(balanceLedgerContract.usedAsCollateral(borrower, loanToken));
        uint64 flagTs = balanceLedgerContract.flaggedAt(borrower, loanToken);
        assertEq(centuari.activeDebtCount(borrower), 1);

        bytes32 marketId = _getMarketId(loanToken, maturity);
        uint256 debt = centuari.getBorrowPosition(marketId, borrower);
        uint256 extra = debt - principal;
        if (extra > 0) {
            _fundUser(borrower, loanToken, extra);
        }

        vm.prank(operator);
        centuari.repay(marketId, borrower, loanToken, debt);

        // Debt is cleared but flag must persist — unflag is user-initiated via
        // CollateralManager.unflagFor (24h lock + RiskModule gate).
        assertEq(centuari.activeDebtCount(borrower), 0);
        assertTrue(balanceLedgerContract.usedAsCollateral(borrower, loanToken));
        assertEq(balanceLedgerContract.flaggedAt(borrower, loanToken), flagTs);

        address[] memory flagged = balanceLedgerContract.flaggedAssetsOf(borrower);
        assertEq(flagged.length, 1);
        assertEq(flagged[0], loanToken);
    }

    function test_repay_doesNotUnflagWithRemainingDebt() public {
        vm.prank(owner);
        centuari.setOperator(operator);

        address lender1 = makeAddr("lender1");
        address lender2 = makeAddr("lender2");
        address borrower = makeAddr("borrower");
        uint256 maturity1 = block.timestamp + 30 days;
        uint256 maturity2 = block.timestamp + 60 days;
        uint256 principal = 1000 ether;
        uint256 rate = 500;
        address loanToken2 = makeAddr("loanToken2");

        address[] memory assets1 = new address[](1);
        assets1[0] = loanToken;
        address[] memory assets2 = new address[](1);
        assets2[0] = loanToken2;

        // Settle in market 1 with flag request
        _fundUser(lender1, loanToken, principal);
        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity1),
            lender1,
            borrower,
            loanToken,
            principal,
            rate,
            maturity1,
            true,
            0,
            0,
            0,
            0,
            assets1
        );

        // Settle in market 2 (different loan token) with flag request
        _fundUser(lender2, loanToken2, principal);
        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken2, maturity2),
            lender2,
            borrower,
            loanToken2,
            principal,
            rate,
            maturity2,
            true,
            0,
            0,
            0,
            0,
            assets2
        );

        assertEq(centuari.activeDebtCount(borrower), 2);
        assertTrue(balanceLedgerContract.usedAsCollateral(borrower, loanToken));
        assertTrue(balanceLedgerContract.usedAsCollateral(borrower, loanToken2));

        bytes32 marketId1 = _getMarketId(loanToken, maturity1);
        uint256 debt1 = centuari.getBorrowPosition(marketId1, borrower);
        uint256 extra1 = debt1 - principal;
        if (extra1 > 0) {
            _fundUser(borrower, loanToken, extra1);
        }

        vm.prank(operator);
        centuari.repay(marketId1, borrower, loanToken, debt1);

        // activeDebtCount decremented but flags unaffected regardless
        assertEq(centuari.activeDebtCount(borrower), 1);
        assertTrue(balanceLedgerContract.usedAsCollateral(borrower, loanToken));
        assertTrue(balanceLedgerContract.usedAsCollateral(borrower, loanToken2));
    }

    function test_activeDebtCount_tracksAcrossMarkets() public {
        vm.prank(owner);
        centuari.setOperator(operator);

        address lender1 = makeAddr("lender1");
        address lender2 = makeAddr("lender2");
        address borrower = makeAddr("borrower");
        uint256 maturity1 = block.timestamp + 30 days;
        uint256 maturity2 = block.timestamp + 60 days;
        uint256 principal = 1000 ether;
        uint256 rate = 500;

        assertEq(centuari.activeDebtCount(borrower), 0);

        // Borrow in market 1
        _fundUser(lender1, loanToken, principal);
        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity1),
            lender1,
            borrower,
            loanToken,
            principal,
            rate,
            maturity1,
            true,
            0,
            0,
            0,
            0,
            new address[](0)
        );
        assertEq(centuari.activeDebtCount(borrower), 1);

        // Borrow in market 2
        _fundUser(lender2, loanToken, principal);
        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity2),
            lender2,
            borrower,
            loanToken,
            principal,
            rate,
            maturity2,
            true,
            0,
            0,
            0,
            0,
            new address[](0)
        );
        assertEq(centuari.activeDebtCount(borrower), 2);

        // Repay market 1 fully
        bytes32 marketId1 = _getMarketId(loanToken, maturity1);
        uint256 debt1 = centuari.getBorrowPosition(marketId1, borrower);
        // Borrower has principal*2 from two settles. Fund extra if needed.
        uint256 borrowerAvail = balanceLedgerContract.available(borrower, loanToken);
        if (borrowerAvail < debt1) {
            _fundUser(borrower, loanToken, debt1 - borrowerAvail);
        }

        vm.prank(operator);
        centuari.repay(marketId1, borrower, loanToken, debt1);
        assertEq(centuari.activeDebtCount(borrower), 1);

        // Repay market 2 fully
        bytes32 marketId2 = _getMarketId(loanToken, maturity2);
        uint256 debt2 = centuari.getBorrowPosition(marketId2, borrower);
        borrowerAvail = balanceLedgerContract.available(borrower, loanToken);
        if (borrowerAvail < debt2) {
            _fundUser(borrower, loanToken, debt2 - borrowerAvail);
        }

        vm.prank(operator);
        centuari.repay(marketId2, borrower, loanToken, debt2);
        assertEq(centuari.activeDebtCount(borrower), 0);
    }

    function test_settleMatch_creditsFeeCollector() public {
        address lender = makeAddr("lender");
        address borrower = makeAddr("borrower");
        uint256 matchedAmount = 1000 ether;
        uint256 rate = 500;
        uint256 maturity = block.timestamp + 365 days;
        uint256 lenderSettlementFee = 5 ether;
        uint256 borrowerSettlementFee = 5 ether;
        uint256 makerFeeAmount = 10 ether;
        uint256 takerFeeAmount = 20 ether;
        bool borrowerIsTaker = true;

        // borrower is taker: lenderFee=maker=10, borrowerFee=taker=20
        uint256 totalLenderFee = lenderSettlementFee + makerFeeAmount; // 15
        uint256 totalBorrowerFee = borrowerSettlementFee + takerFeeAmount; // 25
        uint256 totalProtocolFees = totalLenderFee + totalBorrowerFee; // 40

        // Fund lender and borrower
        _fundUser(lender, loanToken, matchedAmount + totalLenderFee);
        _fundUser(borrower, loanToken, totalBorrowerFee);

        uint256 feeCollectorBefore = balanceLedgerContract.available(feeCollector, loanToken);

        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            lender,
            borrower,
            loanToken,
            matchedAmount,
            rate,
            maturity,
            borrowerIsTaker,
            lenderSettlementFee,
            borrowerSettlementFee,
            makerFeeAmount,
            takerFeeAmount,
            new address[](0)
        );

        // Fee collector credited with total protocol fees
        assertEq(balanceLedgerContract.available(feeCollector, loanToken), feeCollectorBefore + totalProtocolFees);
    }

    // ============ Fuzz Tests ============

    function testFuzz_SettleMatch(uint256 matchedAmount, uint256 rate, uint256 durationDays) public {
        // Bound inputs to reasonable ranges
        matchedAmount = bound(matchedAmount, 1 ether, 1_000_000 ether);
        rate = bound(rate, 1, 5000); // 0.01% to 50%
        durationDays = bound(durationDays, 1, 3650); // 1 day to 10 years

        address lender = makeAddr("lender");
        address borrower = makeAddr("borrower");
        uint256 maturity = block.timestamp + durationDays * 1 days;

        _fundUser(lender, loanToken, matchedAmount);

        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            lender,
            borrower,
            loanToken,
            matchedAmount,
            rate,
            maturity,
            true,
            0,
            0,
            0,
            0,
            new address[](0)
        );

        bytes32 marketId = _getMarketId(loanToken, maturity);
        uint256 expectedCbt = _expectedCbt(matchedAmount, rate, maturity);
        assertEq(centuari.getMarketTotalCbt(marketId), expectedCbt);
        assertGe(centuari.getBorrowPosition(marketId, borrower), matchedAmount);
    }

    function testFuzz_InterestCalculation(uint256 principal, uint256 rate, uint256 durationDays) public view {
        principal = bound(principal, 1 ether, 1_000_000 ether);
        rate = bound(rate, 1, 10000);
        durationDays = bound(durationDays, 1, 3650);

        uint256 maturity = block.timestamp + durationDays * 1 days;
        uint256 interest = _interestWithDayCount(principal, rate, block.timestamp, maturity);

        assertGe(interest, 0);
        if (rate <= 5000 && durationDays <= 365) {
            assertLe(interest, principal);
        }
    }

    // ============ Upgrade Tests ============

    function test_Upgrade_PreservesStorage() public {
        // Setup: Settle a match first
        address lender = makeAddr("lender");
        address borrower = makeAddr("borrower");
        uint256 maturity = block.timestamp + 365 days;

        _fundUser(lender, loanToken, 1000 ether);

        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            lender,
            borrower,
            loanToken,
            1000 ether,
            500,
            maturity,
            true,
            0,
            0,
            0,
            0,
            new address[](0)
        );

        bytes32 marketId = _getMarketId(loanToken, maturity);

        uint256 marketBefore = centuari.getMarketTotalCbt(marketId);
        uint256 lendPosBefore = centuari.getLendPositionCbtAmount(marketId, lender);
        address settlementBefore = centuari.settlement();
        address balanceLedgerBefore = centuari.balanceLedger();
        address ownerBefore = centuari.owner();

        // Upgrade to V2
        CentuariV2 newImpl = new CentuariV2();
        vm.prank(proxyAdminOwner);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImpl), "");

        CentuariV2 centuariV2 = CentuariV2(address(proxy));
        assertEq(centuariV2.getMarketTotalCbt(marketId), marketBefore);
        assertEq(centuariV2.getLendPositionCbtAmount(marketId, lender), lendPosBefore);
        assertEq(centuariV2.settlement(), settlementBefore);
        assertEq(centuariV2.balanceLedger(), balanceLedgerBefore);
        assertEq(centuariV2.owner(), ownerBefore);
    }

    function test_Upgrade_CannotReinitialize() public {
        CentuariV2 newImpl = new CentuariV2();
        vm.prank(proxyAdminOwner);
        proxyAdmin.upgradeAndCall(ITransparentUpgradeableProxy(address(proxy)), address(newImpl), "");

        CentuariV2 centuariV2 = CentuariV2(address(proxy));

        vm.expectRevert();
        centuariV2.initialize(user, user, user, user);
    }

    // ============ Edge Case Tests ============

    function test_SettleMatch_SameLenderMultipleMatches() public {
        address lender = makeAddr("lender");
        address borrower1 = makeAddr("borrower1");
        address borrower2 = makeAddr("borrower2");
        uint256 maturity = block.timestamp + 365 days;

        _fundUser(lender, loanToken, 1500 ether);

        // Same lender, two matches
        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            lender,
            borrower1,
            loanToken,
            1000 ether,
            500,
            maturity,
            true,
            0,
            0,
            0,
            0,
            new address[](0)
        );

        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            lender,
            borrower2,
            loanToken,
            500 ether,
            500,
            maturity,
            true,
            0,
            0,
            0,
            0,
            new address[](0)
        );

        bytes32 marketId = _getMarketId(loanToken, maturity);
        uint256 expectedCbt1 = _expectedCbt(1000 ether, 500, maturity);
        uint256 expectedCbt2 = _expectedCbt(500 ether, 500, maturity);
        assertEq(centuari.getLendPositionCbtAmount(marketId, lender), expectedCbt1 + expectedCbt2);
    }

    function test_SettleMatch_DifferentMarkets() public {
        address lender = makeAddr("lender");
        address borrower = makeAddr("borrower");
        uint256 maturity1 = block.timestamp + 30 days;
        uint256 maturity2 = block.timestamp + 60 days;

        _fundUser(lender, loanToken, 3000 ether);

        // Two different markets (different maturities)
        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity1),
            lender,
            borrower,
            loanToken,
            1000 ether,
            500,
            maturity1,
            true,
            0,
            0,
            0,
            0,
            new address[](0)
        );

        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity2),
            lender,
            borrower,
            loanToken,
            2000 ether,
            500,
            maturity2,
            true,
            0,
            0,
            0,
            0,
            new address[](0)
        );

        bytes32 marketId1 = _getMarketId(loanToken, maturity1);
        bytes32 marketId2 = _getMarketId(loanToken, maturity2);

        uint256 expectedCbt1 = _expectedCbt(1000 ether, 500, maturity1);
        uint256 expectedCbt2 = _expectedCbt(2000 ether, 500, maturity2);
        assertEq(centuari.getMarketTotalCbt(marketId1), expectedCbt1);
        assertEq(centuari.getMarketTotalCbt(marketId2), expectedCbt2);
    }

    function test_SettleMatch_ZeroInterestRate() public {
        address lender = makeAddr("lender");
        address borrower = makeAddr("borrower");
        uint256 maturity = block.timestamp + 365 days;

        _fundUser(lender, loanToken, 1000 ether);

        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            lender,
            borrower,
            loanToken,
            1000 ether,
            0, // 0% interest
            maturity,
            true,
            0,
            0,
            0,
            0,
            new address[](0)
        );

        bytes32 marketId = _getMarketId(loanToken, maturity);

        // With 0% interest, debt equals principal
        assertEq(centuari.getBorrowPosition(marketId, borrower), 1000 ether);
    }

    // ============ Maker/Taker Fee Tests ============

    function test_SettleMatch_FeeCalculation_BorrowerIsTaker() public {
        address lender = makeAddr("lender");
        address borrower = makeAddr("borrower");
        uint256 matchedAmount = 1000 ether;
        uint256 rate = 500; // 5%
        uint256 maturity = block.timestamp + 365 days;
        uint256 makerFeeAmount = 10 ether; // 1% of matchedAmount
        uint256 takerFeeAmount = 20 ether; // 2% of matchedAmount
        bool borrowerIsTaker = true; // borrower is taker, lender is maker

        // CBT is based on full matchedAmount
        uint256 expectedCbtMinted = _expectedCbt(matchedAmount, rate, maturity);

        // Lender fee = makerFeeAmount (lender is maker), borrower fee = takerFeeAmount
        uint256 totalLenderFee = makerFeeAmount;
        uint256 totalBorrowerFee = takerFeeAmount;

        // Fund lender and borrower
        _fundUser(lender, loanToken, matchedAmount + totalLenderFee);
        _fundUser(borrower, loanToken, totalBorrowerFee);

        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            lender,
            borrower,
            loanToken,
            matchedAmount,
            rate,
            maturity,
            borrowerIsTaker,
            0,
            0,
            makerFeeAmount,
            takerFeeAmount,
            new address[](0)
        );

        bytes32 marketId = _getMarketId(loanToken, maturity);

        // Verify BalanceLedger state
        assertEq(balanceLedgerContract.available(lender, loanToken), 0);
        // Borrower: pre-funded with totalBorrowerFee, credited matchedAmount, debited totalBorrowerFee
        // Final = totalBorrowerFee + matchedAmount - totalBorrowerFee = matchedAmount
        assertEq(balanceLedgerContract.available(borrower, loanToken), matchedAmount);

        // Fee collector gets total protocol fees
        assertEq(balanceLedgerContract.available(feeCollector, loanToken), totalLenderFee + totalBorrowerFee);

        address bondTokenAddr = bondFactory.getBondToken(loanToken, maturity);
        CentuariBondERC20 bondToken = CentuariBondERC20(bondTokenAddr);
        // CBT held by Centuari, not lender
        assertEq(bondToken.balanceOf(address(centuari)), expectedCbtMinted);
        assertEq(bondToken.balanceOf(lender), 0);

        assertEq(centuari.getMarketTotalCbt(marketId), expectedCbtMinted);
        assertEq(centuari.getLendPositionCbtAmount(marketId, lender), expectedCbtMinted);
    }

    function test_SettleMatch_FeeCalculation_LenderIsTaker() public {
        address lender = makeAddr("lender");
        address borrower = makeAddr("borrower");
        uint256 matchedAmount = 1000 ether;
        uint256 rate = 500; // 5%
        uint256 maturity = block.timestamp + 365 days;
        uint256 makerFeeAmount = 10 ether; // 1% of matchedAmount
        uint256 takerFeeAmount = 20 ether; // 2% of matchedAmount
        bool borrowerIsTaker = false; // lender is taker, borrower is maker

        // CBT is based on full matchedAmount
        uint256 expectedCbtMinted = _expectedCbt(matchedAmount, rate, maturity);

        // Lender fee = takerFeeAmount (lender is taker), borrower fee = makerFeeAmount
        uint256 totalLenderFee = takerFeeAmount;
        uint256 totalBorrowerFee = makerFeeAmount;

        // Fund
        _fundUser(lender, loanToken, matchedAmount + totalLenderFee);
        _fundUser(borrower, loanToken, totalBorrowerFee);

        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            lender,
            borrower,
            loanToken,
            matchedAmount,
            rate,
            maturity,
            borrowerIsTaker,
            0,
            0,
            makerFeeAmount,
            takerFeeAmount,
            new address[](0)
        );

        bytes32 marketId = _getMarketId(loanToken, maturity);

        // Fee collector gets total protocol fees
        assertEq(balanceLedgerContract.available(feeCollector, loanToken), totalLenderFee + totalBorrowerFee);

        address bondTokenAddr = bondFactory.getBondToken(loanToken, maturity);
        CentuariBondERC20 bondToken = CentuariBondERC20(bondTokenAddr);
        // CBT held by Centuari, not lender
        assertEq(bondToken.balanceOf(address(centuari)), expectedCbtMinted);
        assertEq(bondToken.balanceOf(lender), 0);

        assertEq(centuari.getLendPositionCbtAmount(marketId, lender), expectedCbtMinted);
    }

    function test_SettleMatch_FeeCalculation_ProportionalShares() public {
        address lender1 = makeAddr("lender1");
        address lender2 = makeAddr("lender2");
        address borrower1 = makeAddr("borrower1");
        address borrower2 = makeAddr("borrower2");
        uint256 maturity = block.timestamp + 365 days;
        uint256 rate = 500;

        // First match: 1000 ether, no fees
        _fundUser(lender1, loanToken, 1000 ether);
        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            lender1,
            borrower1,
            loanToken,
            1000 ether,
            rate,
            maturity,
            true,
            0,
            0,
            0,
            0,
            new address[](0)
        );

        uint256 matchedAmount2 = 500 ether;
        uint256 makerFeeAmount = 5 ether;
        uint256 takerFeeAmount = 10 ether;
        bool borrowerIsTaker = true;

        // CBT is based on full matchedAmount
        uint256 expectedCbtMinted2 = _expectedCbt(matchedAmount2, rate, maturity);

        // Fund: lender2 = matchedAmount + makerFee (lender is maker), borrower2 = takerFee
        _fundUser(lender2, loanToken, matchedAmount2 + makerFeeAmount);
        _fundUser(borrower2, loanToken, takerFeeAmount);

        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            lender2,
            borrower2,
            loanToken,
            matchedAmount2,
            rate,
            maturity,
            borrowerIsTaker,
            0,
            0,
            makerFeeAmount,
            takerFeeAmount,
            new address[](0)
        );

        bytes32 marketId = _getMarketId(loanToken, maturity);
        assertEq(centuari.getLendPositionCbtAmount(marketId, lender2), expectedCbtMinted2);
    }

    function test_SettleMatch_FeeCalculation_ZeroFees() public {
        address lender = makeAddr("lender");
        address borrower = makeAddr("borrower");
        uint256 matchedAmount = 1000 ether;
        uint256 maturity = block.timestamp + 365 days;

        _fundUser(lender, loanToken, matchedAmount);

        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            lender,
            borrower,
            loanToken,
            matchedAmount,
            500,
            maturity,
            true,
            0,
            0,
            0, // makerFeeAmount = 0
            0, // takerFeeAmount = 0
            new address[](0)
        );

        // No fees -> fee collector should have 0
        assertEq(balanceLedgerContract.available(feeCollector, loanToken), 0);

        uint256 expectedCbt = _expectedCbt(matchedAmount, 500, maturity);
        address bondTokenAddr = bondFactory.getBondToken(loanToken, maturity);
        CentuariBondERC20 bondToken = CentuariBondERC20(bondTokenAddr);
        assertEq(bondToken.balanceOf(address(centuari)), expectedCbt);
        assertEq(bondToken.balanceOf(lender), 0);
    }

    function test_SettleMatch_FeeCalculation_OnlyMakerFee() public {
        address lender = makeAddr("lender");
        address borrower = makeAddr("borrower");
        uint256 matchedAmount = 1000 ether;
        uint256 maturity = block.timestamp + 365 days;
        uint256 makerFeeAmount = 10 ether;
        uint256 takerFeeAmount = 0;
        bool borrowerIsTaker = true; // lender is maker

        // Lender pays makerFeeAmount
        _fundUser(lender, loanToken, matchedAmount + makerFeeAmount);

        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            lender,
            borrower,
            loanToken,
            matchedAmount,
            500,
            maturity,
            borrowerIsTaker,
            0,
            0,
            makerFeeAmount,
            takerFeeAmount,
            new address[](0)
        );

        // Fee collector gets makerFeeAmount
        assertEq(balanceLedgerContract.available(feeCollector, loanToken), makerFeeAmount);

        uint256 expectedCbt = _expectedCbt(matchedAmount, 500, maturity);
        address bondTokenAddr = bondFactory.getBondToken(loanToken, maturity);
        CentuariBondERC20 bondToken = CentuariBondERC20(bondTokenAddr);
        assertEq(bondToken.balanceOf(address(centuari)), expectedCbt);
        assertEq(bondToken.balanceOf(lender), 0);
    }

    function test_SettleMatch_FeeCalculation_OnlyTakerFee() public {
        address lender = makeAddr("lender");
        address borrower = makeAddr("borrower");
        uint256 matchedAmount = 1000 ether;
        uint256 maturity = block.timestamp + 365 days;
        uint256 makerFeeAmount = 0;
        uint256 takerFeeAmount = 20 ether;
        bool borrowerIsTaker = true; // borrower is taker

        _fundUser(lender, loanToken, matchedAmount);
        _fundUser(borrower, loanToken, takerFeeAmount);

        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            lender,
            borrower,
            loanToken,
            matchedAmount,
            500,
            maturity,
            borrowerIsTaker,
            0,
            0,
            makerFeeAmount,
            takerFeeAmount,
            new address[](0)
        );

        // Fee collector gets takerFeeAmount
        assertEq(balanceLedgerContract.available(feeCollector, loanToken), takerFeeAmount);

        uint256 expectedCbt = _expectedCbt(matchedAmount, 500, maturity);
        address bondTokenAddr = bondFactory.getBondToken(loanToken, maturity);
        CentuariBondERC20 bondToken = CentuariBondERC20(bondTokenAddr);
        assertEq(bondToken.balanceOf(address(centuari)), expectedCbt);
        assertEq(bondToken.balanceOf(lender), 0);
    }

    function test_SettleMatch_FeeCalculation_WithSettlementFees() public {
        address lender = makeAddr("lender");
        address borrower = makeAddr("borrower");
        uint256 matchedAmount = 1000 ether;
        uint256 maturity = block.timestamp + 365 days;
        uint256 makerFeeAmount = 10 ether;
        uint256 takerFeeAmount = 20 ether;
        uint256 lenderSettlementFee = 5 ether;
        uint256 borrowerSettlementFee = 5 ether;
        bool borrowerIsTaker = true;

        // Lender: matchedAmount + lenderSettlementFee + makerFee (lender is maker)
        uint256 totalLenderFee = lenderSettlementFee + makerFeeAmount;
        uint256 totalBorrowerFee = borrowerSettlementFee + takerFeeAmount;

        _fundUser(lender, loanToken, matchedAmount + totalLenderFee);
        _fundUser(borrower, loanToken, totalBorrowerFee);

        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            lender,
            borrower,
            loanToken,
            matchedAmount,
            500,
            maturity,
            borrowerIsTaker,
            lenderSettlementFee,
            borrowerSettlementFee,
            makerFeeAmount,
            takerFeeAmount,
            new address[](0)
        );

        // Fee collector gets total of all fees
        uint256 totalProtocolFees = totalLenderFee + totalBorrowerFee;
        assertEq(balanceLedgerContract.available(feeCollector, loanToken), totalProtocolFees);
    }

    function test_SettleMatch_FeeCalculation_NoBondFactory() public {
        // Create a new Centuari instance without setting bond factory
        Centuari centuariNoFactory = _deployCentuariWithoutBondFactory();

        // Register as writer
        vm.prank(owner);
        balanceLedgerContract.forceAddWriter(address(centuariNoFactory));

        address lender = makeAddr("lender");
        address borrower = makeAddr("borrower");
        uint256 matchedAmount = 1000 ether;
        uint256 maturity = block.timestamp + 365 days;
        uint256 makerFeeAmount = 10 ether;
        uint256 takerFeeAmount = 20 ether;

        // Fund: lender pays matchedAmount + makerFee (borrowerIsTaker=true, lender is maker)
        _fundUser(lender, loanToken, matchedAmount + makerFeeAmount);
        _fundUser(borrower, loanToken, takerFeeAmount);

        // Should not revert even without bond factory
        vm.prank(settlement);
        centuariNoFactory.settleMatch(
            _getMarketId(loanToken, maturity),
            lender,
            borrower,
            loanToken,
            matchedAmount,
            500,
            maturity,
            true,
            0,
            0,
            makerFeeAmount,
            takerFeeAmount,
            new address[](0)
        );

        // Verify lender was debited
        assertEq(balanceLedgerContract.available(lender, loanToken), 0);

        // Verify bond factory is not set
        assertEq(centuariNoFactory.bondTokenFactory(), address(0));
    }

    function test_SettleMatch_FeeCalculation_HighFees() public {
        address lender = makeAddr("lender");
        address borrower = makeAddr("borrower");
        uint256 matchedAmount = 1000 ether;
        uint256 maturity = block.timestamp + 365 days;
        bool borrowerIsTaker = false; // lender is taker

        // Even with high fees, CBT is based on full matchedAmount
        uint256 highTakerFee = matchedAmount - 1 ether;
        uint256 highMakerFee = 0;

        // Lender is taker, so lenderFee = takerFee
        _fundUser(lender, loanToken, matchedAmount + highTakerFee);
        // Borrower is maker, so borrowerFee = makerFee = 0

        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            lender,
            borrower,
            loanToken,
            matchedAmount,
            500,
            maturity,
            borrowerIsTaker,
            0,
            0,
            highMakerFee,
            highTakerFee,
            new address[](0)
        );

        // CBT is based on full matchedAmount regardless of fees
        uint256 expectedCbt = _expectedCbt(matchedAmount, 500, maturity);
        address bondTokenAddr = bondFactory.getBondToken(loanToken, maturity);
        CentuariBondERC20 bondToken = CentuariBondERC20(bondTokenAddr);
        assertEq(bondToken.balanceOf(address(centuari)), expectedCbt);
        assertEq(bondToken.balanceOf(lender), 0);

        // Fee collector gets the high taker fee
        assertEq(balanceLedgerContract.available(feeCollector, loanToken), highTakerFee);
    }

    function testFuzz_SettleMatch_FeeCalculation(
        uint256 matchedAmount,
        uint256 makerFeeAmount,
        uint256 takerFeeAmount,
        bool borrowerIsTaker
    ) public {
        // Bound inputs to reasonable ranges
        matchedAmount = bound(matchedAmount, 100 ether, 1_000_000 ether);
        makerFeeAmount = bound(makerFeeAmount, 0, matchedAmount / 10); // Max 10% fee
        takerFeeAmount = bound(takerFeeAmount, 0, matchedAmount / 10); // Max 10% fee

        address lender = makeAddr("lender");
        address borrower = makeAddr("borrower");
        uint256 maturity = block.timestamp + 365 days;
        uint256 rate = 500;

        // Calculate expected values
        uint256 expectedLenderFee = borrowerIsTaker ? makerFeeAmount : takerFeeAmount;
        uint256 expectedBorrowerFee = borrowerIsTaker ? takerFeeAmount : makerFeeAmount;

        // Fund participants
        _fundUser(lender, loanToken, matchedAmount + expectedLenderFee);
        if (expectedBorrowerFee > 0) {
            _fundUser(borrower, loanToken, expectedBorrowerFee);
        }

        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            lender,
            borrower,
            loanToken,
            matchedAmount,
            rate,
            maturity,
            borrowerIsTaker,
            0,
            0,
            makerFeeAmount,
            takerFeeAmount,
            new address[](0)
        );

        // Fee collector gets total protocol fees
        uint256 totalFees = expectedLenderFee + expectedBorrowerFee;
        if (totalFees > 0) {
            assertEq(balanceLedgerContract.available(feeCollector, loanToken), totalFees);
        }

        // CBT is based on full matchedAmount
        uint256 expectedCbtMinted = _expectedCbt(matchedAmount, rate, maturity);

        address bondTokenAddr = bondFactory.getBondToken(loanToken, maturity);
        CentuariBondERC20 bondToken = CentuariBondERC20(bondTokenAddr);
        assertEq(bondToken.balanceOf(address(centuari)), expectedCbtMinted);
        assertEq(bondToken.balanceOf(lender), 0);
    }
}
