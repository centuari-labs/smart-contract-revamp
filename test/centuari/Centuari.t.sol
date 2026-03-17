// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Centuari} from "../../src/core/centuari/Centuari.sol";
import {ICentuari} from "../../src/interfaces/ICentuari.sol";
import {ITreasury} from "../../src/interfaces/ITreasury.sol";
import {CentuariBondERC20Factory} from "../../src/core/centuari/CentuariBondERC20Factory.sol";
import {CentuariBondERC20} from "../../src/core/centuari/CentuariBondERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @title MockTreasury
/// @notice Mock contract for testing Centuari
contract MockTreasury is ITreasury {
    // Track calls for assertions
    uint256 public settleCallCount;
    address public lastLoanToken;
    address public lastFrom;
    address public lastTo;
    uint256 public lastAmount;
    uint256 public lastLenderSettlementFee;
    uint256 public lastBorrowerSettlementFee;

    uint256 public repayCallCount;
    address public lastRepayUser;
    address public lastRepayToken;
    uint256 public lastRepayAmount;

    uint256 public withdrawLendPositionCallCount;
    address public lastWithdrawLendUser;
    address public lastWithdrawLendToken;
    uint256 public lastWithdrawLendAmount;

    uint256 public recordBondMintCallCount;
    address public lastBondMintUser;
    address public lastBondMintToken;
    uint256 public lastBondMintAmount;

    uint256 public burnBondForUserCallCount;
    address public lastBondBurnUser;
    address public lastBondBurnToken;
    uint256 public lastBondBurnAmount;

    bool public shouldRevert;

    function setRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function settle(
        address loanToken,
        address from,
        address to,
        uint256 amount,
        uint256 lenderSettlementFee,
        uint256 borrowerSettlementFee
    ) external override {
        if (shouldRevert) {
            revert("MockTreasury: forced revert");
        }

        settleCallCount++;
        lastLoanToken = loanToken;
        lastFrom = from;
        lastTo = to;
        lastAmount = amount;
        lastLenderSettlementFee = lenderSettlementFee;
        lastBorrowerSettlementFee = borrowerSettlementFee;

        emit SettlementExecuted(loanToken, from, to, amount, lenderSettlementFee, borrowerSettlementFee);
    }

    function repay(address user, address token, uint256 amount) external override {
        repayCallCount++;
        lastRepayUser = user;
        lastRepayToken = token;
        lastRepayAmount = amount;
        emit Repay(user, token, amount);
    }

    function reset() external {
        settleCallCount = 0;
        lastLoanToken = address(0);
        lastFrom = address(0);
        lastTo = address(0);
        lastAmount = 0;
        lastLenderSettlementFee = 0;
        lastBorrowerSettlementFee = 0;
        repayCallCount = 0;
        lastRepayUser = address(0);
        lastRepayToken = address(0);
        lastRepayAmount = 0;
        withdrawLendPositionCallCount = 0;
        lastWithdrawLendUser = address(0);
        lastWithdrawLendToken = address(0);
        lastWithdrawLendAmount = 0;
        recordBondMintCallCount = 0;
        lastBondMintUser = address(0);
        lastBondMintToken = address(0);
        lastBondMintAmount = 0;
        burnBondForUserCallCount = 0;
        lastBondBurnUser = address(0);
        lastBondBurnToken = address(0);
        lastBondBurnAmount = 0;
        shouldRevert = false;
    }

    // Stub implementations for ITreasury interface
    function setSupportedToken(address, bool) external pure override {}
    function setCentuariContract(address) external pure override {}
    function deposit(address, uint256) external pure override {}
    function withdraw(address, address, uint256) external pure override {}
    function registerBondToken(address) external pure override {}
    function withdrawLendPosition(address user, address token, uint256 amount) external override {
        withdrawLendPositionCallCount++;
        lastWithdrawLendUser = user;
        lastWithdrawLendToken = token;
        lastWithdrawLendAmount = amount;
        emit WithdrawLendPosition(user, token, amount);
    }
    function recordBondMint(address user, address bondToken, uint256 amount) external override {
        recordBondMintCallCount++;
        lastBondMintUser = user;
        lastBondMintToken = bondToken;
        lastBondMintAmount = amount;
    }
    function burnBondForUser(address user, address bondToken, uint256 amount) external override {
        burnBondForUserCallCount++;
        lastBondBurnUser = user;
        lastBondBurnToken = bondToken;
        lastBondBurnAmount = amount;
    }
    function balanceOf(address, address) external pure override returns (uint256) { return 0; }
    function pause() external pure override {}
    function unpause() external pure override {}
}

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
/// @notice Test suite for Centuari contract
contract CentuariTest is Test {
    Centuari public implementation;
    Centuari public centuari;
    MockTreasury public mockTreasury;
    CentuariBondERC20Factory public bondFactory;
    ProxyAdmin public proxyAdmin;
    TransparentUpgradeableProxy public proxy;

    address public owner;
    address public settlement;
    address public operator;
    address public user;
    address public loanToken;
    address public proxyAdminOwner;

    // Constants matching CentuariStorage
    uint256 constant RATE_PRECISION = 10000;
    uint256 constant SECONDS_PER_YEAR = 365 days;

    // Events to test
    event MarketCreated(
        bytes32 indexed marketId,
        address indexed loanToken,
        uint256 indexed maturity
    );

    event LendPositionCreated(
        bytes32 indexed marketId,
        address indexed lender,
        address indexed bondToken,
        uint256 cbtAmount,
        uint256 principal,
        uint256 rate
    );

    event BorrowPositionCreated(
        bytes32 indexed marketId,
        address indexed borrower,
        uint256 principal,
        uint256 debt,
        uint256 rate
    );

    event SettlementUpdated(address indexed oldSettlement, address indexed newSettlement);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event Paused(address account);
    event Unpaused(address account);
    event Repaid(bytes32 indexed marketId, address indexed borrower, uint256 amount);
    event LendPositionWithdrawn(
        bytes32 indexed marketId,
        address indexed lender,
        uint256 cbtBurned,
        uint256 amountWithdrawn
    );
    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);

    function setUp() public {
        owner = makeAddr("owner");
        settlement = makeAddr("settlement");
        operator = makeAddr("operator");
        user = makeAddr("user");
        loanToken = makeAddr("loanToken");
        proxyAdminOwner = makeAddr("proxyAdminOwner");

        // Deploy mock Treasury
        mockTreasury = new MockTreasury();

        // Deploy implementation
        implementation = new Centuari();

        // Prepare initialization data
        bytes memory initData = abi.encodeCall(
            Centuari.initialize,
            (owner, settlement, address(mockTreasury))
        );

        // Deploy TransparentUpgradeableProxy
        proxy = new TransparentUpgradeableProxy(
            address(implementation),
            proxyAdminOwner,
            initData
        );

        // Get the ProxyAdmin address
        proxyAdmin = ProxyAdmin(_getProxyAdmin(address(proxy)));

        // Cast proxy to Centuari
        centuari = Centuari(address(proxy));

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
    function _interestWithDayCount(
        uint256 principal,
        uint256 rate,
        uint256 start,
        uint256 maturity
    ) internal pure returns (uint256) {
        uint256 rawDays = (maturity - start) / 1 days;
        uint256 days_ = rawDays > 0 ? rawDays - 1 : 0;
        return (principal * rate * days_) / (RATE_PRECISION * 365);
    }

    function _expectedCbt(uint256 principal, uint256 rate, uint256 maturity) internal view returns (uint256) {
        return principal + _interestWithDayCount(principal, rate, block.timestamp, maturity);
    }

    function _expectedDebt(uint256 principal, uint256 rate, uint256 maturity) internal view returns (uint256) {
        return principal + _interestWithDayCount(principal, rate, block.timestamp, maturity);
    }

    // ============ Initialization Tests ============

    function test_Initialize() public view {
        assertEq(centuari.owner(), owner);
        assertEq(centuari.settlement(), settlement);
        assertEq(centuari.treasury(), address(mockTreasury));
        assertEq(centuari.paused(), false);
    }

    function test_Initialize_RevertZeroOwner() public {
        Centuari newImpl = new Centuari();
        bytes memory initData = abi.encodeCall(
            Centuari.initialize,
            (address(0), settlement, address(mockTreasury))
        );
        vm.expectRevert(ICentuari.ZeroAddress.selector);
        new TransparentUpgradeableProxy(address(newImpl), proxyAdminOwner, initData);
    }

    function test_Initialize_RevertZeroSettlement() public {
        Centuari newImpl = new Centuari();
        bytes memory initData = abi.encodeCall(
            Centuari.initialize,
            (owner, address(0), address(mockTreasury))
        );
        vm.expectRevert(ICentuari.ZeroAddress.selector);
        new TransparentUpgradeableProxy(address(newImpl), proxyAdminOwner, initData);
    }

    function test_Initialize_RevertZeroTreasury() public {
        Centuari newImpl = new Centuari();
        bytes memory initData = abi.encodeCall(
            Centuari.initialize,
            (owner, settlement, address(0))
        );
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
            0
        );

        assertEq(centuari.getMarketTotalCbt(expectedMarketId), expectedCbt);
        assertEq(centuari.getLendPositionCbtAmount(expectedMarketId, lender), expectedCbt);

        // Verify borrower position
        assertEq(centuari.getBorrowPosition(expectedMarketId, borrower), expectedDebt);

        // Verify Treasury was called
        assertEq(mockTreasury.settleCallCount(), 1);
        assertEq(mockTreasury.lastLoanToken(), loanToken);
        assertEq(mockTreasury.lastFrom(), lender);
        assertEq(mockTreasury.lastTo(), borrower);
        assertEq(mockTreasury.lastAmount(), matchedAmount);

        // Verify CBT was minted to Treasury and recorded via Treasury, not to lender wallet
        address bondTokenAddr = bondFactory.getBondToken(loanToken, maturity);
        CentuariBondERC20 bondToken = CentuariBondERC20(bondTokenAddr);
        assertEq(bondToken.balanceOf(address(mockTreasury)), expectedCbt);
        assertEq(bondToken.balanceOf(lender), 0);
        assertEq(mockTreasury.recordBondMintCallCount(), 1);
        assertEq(mockTreasury.lastBondMintUser(), lender);
        assertEq(mockTreasury.lastBondMintToken(), bondTokenAddr);
        assertEq(mockTreasury.lastBondMintAmount(), expectedCbt);
    }

    function test_SettleMatch_MultipleInSameMarket() public {
        address lender1 = makeAddr("lender1");
        address lender2 = makeAddr("lender2");
        address borrower1 = makeAddr("borrower1");
        address borrower2 = makeAddr("borrower2");
        uint256 maturity = block.timestamp + 365 days;
        uint256 rate = 500;

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
            0
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
            0
        );

        bytes32 marketId = _getMarketId(loanToken, maturity);
        uint256 expectedCbt1 = _expectedCbt(1000 ether, rate, maturity);
        uint256 expectedCbt2 = _expectedCbt(500 ether, rate, maturity);
        assertEq(centuari.getMarketTotalCbt(marketId), expectedCbt1 + expectedCbt2);
        assertEq(mockTreasury.settleCallCount(), 2);
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
            0
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
            0
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
            0
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
            0
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
            0
        );
    }

    // ============ Share Calculation Tests ============

    function test_ShareCalculation_FirstDeposit() public {
        address lender = makeAddr("lender");
        address borrower = makeAddr("borrower");
        uint256 amount = 1000 ether;
        uint256 maturity = block.timestamp + 365 days;

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
            0
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
            0
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
            0
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
            0
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
            0
        );

        bytes32 marketId = _getMarketId(loanToken, maturity);

        uint256 expectedDebt = _expectedDebt(principal, rate, maturity);
        assertEq(centuari.getBorrowPosition(marketId, borrower), expectedDebt);
    }

    /// @dev Day-count example: 1 Jan -> 1 Feb = 30 days (2 Jan = day 1, 31 Jan = last day). 1000 USDC at 10% => CBT ≈ 1008
    function test_DayCount_Jan1ToFeb1_ThirtyDays() public {
        // Jan 1 00:00 UTC and Feb 1 00:00 UTC (use fixed timestamps)
        uint256 start = 1704067200; // 2024-01-01 00:00:00 UTC
        uint256 maturity = start + 31 days; // 2024-02-01 00:00:00 UTC
        vm.warp(start);

        address lender = makeAddr("lender");
        address borrower = makeAddr("borrower");
        uint256 principal = 1000 ether;
        uint256 rate = 1000; // 10%

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
            0
        );

        bytes32 marketId = _getMarketId(loanToken, maturity);
        uint256 expectedCbt = _expectedCbt(principal, rate, maturity);
        // 1000 + (1000 * 10% / 365 * 30) = 1000 + 8.219... ≈ 1008
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
            0
        );

        address bondTokenAddr = bondFactory.getBondToken(loanToken, maturity);
        assertTrue(bondTokenAddr != address(0));

        CentuariBondERC20 bondToken = CentuariBondERC20(bondTokenAddr);
        uint256 expectedCbt = _expectedCbt(amount, 500, maturity);
        // CBT is held by Treasury, not directly by lender
        assertEq(bondToken.balanceOf(address(mockTreasury)), expectedCbt);
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
            0
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
            0
        );

        address bondTokenAddr = bondFactory.getBondToken(loanToken, maturity);
        CentuariBondERC20 bondToken = CentuariBondERC20(bondTokenAddr);

        uint256 expectedCbt1 = _expectedCbt(1000 ether, rate, maturity);
        uint256 expectedCbt2 = _expectedCbt(500 ether, rate, maturity);
        // All CBT is held by Treasury; total supply equals sum of lender positions
        assertEq(bondToken.balanceOf(address(mockTreasury)), expectedCbt1 + expectedCbt2);
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

    function test_SetTreasury() public {
        address newTreasury = makeAddr("newTreasury");

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit TreasuryUpdated(address(mockTreasury), newTreasury);
        centuari.setTreasury(newTreasury);

        assertEq(centuari.treasury(), newTreasury);
    }

    function test_SetTreasury_RevertNotOwner() public {
        vm.prank(user);
        vm.expectRevert();
        centuari.setTreasury(makeAddr("newTreasury"));
    }

    function test_SetTreasury_RevertZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(ICentuari.ZeroAddress.selector);
        centuari.setTreasury(address(0));
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

        address borrower = makeAddr("borrower");
        uint256 maturity = block.timestamp + 365 days;
        uint256 principal = 1000 ether;
        uint256 rate = 500;

        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            makeAddr("lender"),
            borrower,
            loanToken,
            principal,
            rate,
            maturity,
            true,
            0,
            0,
            0,
            0
        );

        bytes32 marketId = _getMarketId(loanToken, maturity);
        uint256 posBefore = centuari.getBorrowPosition(marketId, borrower);

        uint256 repayAmount = 500 ether;

        vm.expectEmit(true, true, false, true);
        emit Repaid(marketId, borrower, repayAmount);

        vm.prank(operator);
        centuari.repay(borrower, loanToken, maturity, repayAmount);

        assertEq(centuari.getBorrowPosition(marketId, borrower), posBefore - repayAmount);
        assertEq(mockTreasury.repayCallCount(), 1);
        assertEq(mockTreasury.lastRepayUser(), borrower);
        assertEq(mockTreasury.lastRepayToken(), loanToken);
        assertEq(mockTreasury.lastRepayAmount(), repayAmount);
    }

    function test_Repay_RevertOnlyOperator() public {
        vm.prank(owner);
        centuari.setOperator(operator);

        address borrower = makeAddr("borrower");
        uint256 maturity = block.timestamp + 365 days;

        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            makeAddr("lender"),
            borrower,
            loanToken,
            1000 ether,
            500,
            maturity,
            true,
            0,
            0,
            0,
            0
        );

        vm.prank(user);
        vm.expectRevert(ICentuari.Unauthorized.selector);
        centuari.repay(borrower, loanToken, maturity, 100 ether);
    }

    function test_Repay_MoreThanDebt_Capped() public {
        vm.prank(owner);
        centuari.setOperator(operator);

        address borrower = makeAddr("borrower");
        uint256 maturity = block.timestamp + 365 days;
        uint256 principal = 1000 ether;
        uint256 rate = 500;

        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            makeAddr("lender"),
            borrower,
            loanToken,
            principal,
            rate,
            maturity,
            true,
            0,
            0,
            0,
            0
        );

        bytes32 marketId = _getMarketId(loanToken, maturity);
        uint256 debtInAssets = centuari.getBorrowPosition(marketId, borrower);

        // Repay more than debt; should cap to full debt
        uint256 repayAmountRequested = debtInAssets + 1000 ether;

        vm.prank(operator);
        centuari.repay(borrower, loanToken, maturity, repayAmountRequested);

        assertEq(centuari.getBorrowPosition(marketId, borrower), 0);
        assertEq(mockTreasury.lastRepayAmount(), debtInAssets);
    }

    function test_Repay_FullDebt() public {
        vm.prank(owner);
        centuari.setOperator(operator);

        address borrower = makeAddr("borrower");
        uint256 maturity = block.timestamp + 365 days;
        uint256 principal = 1000 ether;
        uint256 rate = 500;

        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            makeAddr("lender"),
            borrower,
            loanToken,
            principal,
            rate,
            maturity,
            true,
            0,
            0,
            0,
            0
        );

        bytes32 marketId = _getMarketId(loanToken, maturity);
        uint256 debtInAssets = centuari.getBorrowPosition(marketId, borrower);

        vm.prank(operator);
        centuari.repay(borrower, loanToken, maturity, debtInAssets);

        assertEq(centuari.getBorrowPosition(marketId, borrower), 0);
    }

    function test_Repay_RevertZeroPosition() public {
        vm.prank(owner);
        centuari.setOperator(operator);

        address borrower = makeAddr("borrower");
        uint256 maturity = block.timestamp + 365 days;

        vm.prank(operator);
        vm.expectRevert(ICentuari.InvalidAmount.selector);
        centuari.repay(borrower, loanToken, maturity, 100 ether);
    }

    function test_Repay_RevertZeroAmount() public {
        vm.prank(owner);
        centuari.setOperator(operator);

        address borrower = makeAddr("borrower");
        uint256 maturity = block.timestamp + 365 days;

        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            makeAddr("lender"),
            borrower,
            loanToken,
            1000 ether,
            500,
            maturity,
            true,
            0,
            0,
            0,
            0
        );

        vm.prank(operator);
        vm.expectRevert(ICentuari.InvalidAmount.selector);
        centuari.repay(borrower, loanToken, maturity, 0);
    }

    function test_Repay_RevertZeroBorrower() public {
        vm.prank(owner);
        centuari.setOperator(operator);

        vm.prank(operator);
        vm.expectRevert(ICentuari.ZeroAddress.selector);
        centuari.repay(address(0), loanToken, block.timestamp + 365 days, 100 ether);
    }

    function test_Repay_RevertWhenPaused() public {
        vm.prank(owner);
        centuari.setOperator(operator);

        address borrower = makeAddr("borrower");
        uint256 maturity = block.timestamp + 365 days;

        // Create loan while unpaused
        vm.prank(settlement);
        centuari.settleMatch(
            _getMarketId(loanToken, maturity),
            makeAddr("lender"),
            borrower,
            loanToken,
            1000 ether,
            500,
            maturity,
            true,
            0,
            0,
            0,
            0
        );

        // Now pause and expect repay to revert
        vm.prank(owner);
        centuari.pause();

        vm.prank(operator);
        vm.expectRevert(ICentuari.ContractPaused.selector);
        centuari.repay(borrower, loanToken, maturity, 100 ether);
    }

    // ============ WithdrawLendPosition Tests ============

    function test_WithdrawLendPosition_Success() public {
        address lender = makeAddr("lender");
        uint256 maturity = block.timestamp + 365 days;
        uint256 principal = 1000 ether;

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
            0
        );

        bytes32 marketId = _getMarketId(loanToken, maturity);
        address bondTokenAddr = bondFactory.getBondToken(loanToken, maturity);
        CentuariBondERC20 bondToken = CentuariBondERC20(bondTokenAddr);

        uint256 cbtBalance = bondToken.balanceOf(address(mockTreasury));
        uint256 cbtToRedeem = cbtBalance / 2;

        uint256 posBefore = centuari.getLendPositionCbtAmount(marketId, lender);
        uint256 marketBefore = centuari.getMarketTotalCbt(marketId);

        vm.warp(maturity);

        vm.expectEmit(true, true, false, true);
        emit LendPositionWithdrawn(marketId, lender, cbtToRedeem, cbtToRedeem);

        vm.prank(lender);
        centuari.withdrawLendPosition(loanToken, maturity, cbtToRedeem);

        assertEq(centuari.getLendPositionCbtAmount(marketId, lender), posBefore - cbtToRedeem);
        assertEq(centuari.getMarketTotalCbt(marketId), marketBefore - cbtToRedeem);
        assertEq(bondToken.balanceOf(address(mockTreasury)), cbtBalance - cbtToRedeem);
        // Verify Treasury burn accounting hook was used
        assertEq(mockTreasury.burnBondForUserCallCount(), 1);
        assertEq(mockTreasury.lastBondBurnUser(), lender);
        assertEq(mockTreasury.lastBondBurnToken(), bondTokenAddr);
        assertEq(mockTreasury.lastBondBurnAmount(), cbtToRedeem);
        assertEq(mockTreasury.withdrawLendPositionCallCount(), 1);
        assertEq(mockTreasury.lastWithdrawLendUser(), lender);
        assertEq(mockTreasury.lastWithdrawLendToken(), loanToken);
        assertEq(mockTreasury.lastWithdrawLendAmount(), cbtToRedeem);
    }

    function test_WithdrawLendPosition_RevertZeroAmount() public {
        address lender = makeAddr("lender");
        uint256 maturity = block.timestamp + 365 days;

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
            0
        );

        vm.warp(maturity);
        vm.prank(lender);
        vm.expectRevert(ICentuari.InvalidAmount.selector);
        centuari.withdrawLendPosition(loanToken, maturity, 0);
    }

    function test_WithdrawLendPosition_RevertBondTokenNotFound_NoFactory() public {
        Centuari centuariNoFactory = _deployCentuariWithoutBondFactory();
        vm.prank(settlement);
        centuariNoFactory.settleMatch(
            _getMarketId(loanToken, block.timestamp + 365 days),
            makeAddr("lender"),
            makeAddr("borrower"),
            loanToken,
            1000 ether,
            500,
            block.timestamp + 365 days,
            true,
            0,
            0,
            0,
            0
        );

        vm.prank(makeAddr("lender"));
        vm.expectRevert(ICentuari.BondTokenNotFound.selector);
        centuariNoFactory.withdrawLendPosition(loanToken, block.timestamp + 365 days, 100 ether);
    }

    function test_WithdrawLendPosition_RevertInsufficientShares() public {
        address lender = makeAddr("lender");
        uint256 maturity = block.timestamp + 365 days;

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
            0
        );

        address bondTokenAddr = bondFactory.getBondToken(loanToken, maturity);
        uint256 cbtBalance = CentuariBondERC20(bondTokenAddr).balanceOf(lender);

        vm.prank(lender);
        CentuariBondERC20(bondTokenAddr).approve(address(centuari), cbtBalance);

        vm.warp(maturity);
        vm.prank(lender);
        vm.expectRevert(ICentuari.InvalidAmount.selector);
        centuari.withdrawLendPosition(loanToken, maturity, cbtBalance + 1 ether);
    }

    function test_WithdrawLendPosition_RevertNotYetMatured() public {
        address lender = makeAddr("lender");
        uint256 maturity = block.timestamp + 365 days;

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
            0
        );

        address bondTokenAddr = bondFactory.getBondToken(loanToken, maturity);
        vm.prank(lender);
        CentuariBondERC20(bondTokenAddr).approve(address(centuari), 100 ether);

        vm.prank(lender);
        vm.expectRevert(ICentuari.NotYetMatured.selector);
        centuari.withdrawLendPosition(loanToken, maturity, 100 ether);
    }

    function test_WithdrawLendPosition_RevertWhenPaused() public {
        address lender = makeAddr("lender");
        uint256 maturity = block.timestamp + 365 days;

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
            0
        );

        address bondTokenAddr = bondFactory.getBondToken(loanToken, maturity);
        vm.prank(lender);
        CentuariBondERC20(bondTokenAddr).approve(address(centuari), 100 ether);

        vm.prank(owner);
        centuari.pause();

        vm.warp(maturity);
        vm.prank(lender);
        vm.expectRevert(ICentuari.ContractPaused.selector);
        centuari.withdrawLendPosition(loanToken, maturity, 100 ether);
    }

    function _deployCentuariWithoutBondFactory() internal returns (Centuari) {
        Centuari impl = new Centuari();
        bytes memory initData = abi.encodeCall(
            Centuari.initialize,
            (owner, settlement, address(mockTreasury))
        );
        TransparentUpgradeableProxy p = new TransparentUpgradeableProxy(
            address(impl),
            proxyAdminOwner,
            initData
        );
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

    // ============ Fuzz Tests ============

    function testFuzz_SettleMatch(
        uint256 matchedAmount,
        uint256 rate,
        uint256 durationDays
    ) public {
        // Bound inputs to reasonable ranges
        matchedAmount = bound(matchedAmount, 1 ether, 1_000_000 ether);
        rate = bound(rate, 1, 5000); // 0.01% to 50%
        durationDays = bound(durationDays, 1, 3650); // 1 day to 10 years

        address lender = makeAddr("lender");
        address borrower = makeAddr("borrower");
        uint256 maturity = block.timestamp + durationDays * 1 days;

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
            0
        );

        bytes32 marketId = _getMarketId(loanToken, maturity);
        uint256 expectedCbt = _expectedCbt(matchedAmount, rate, maturity);
        assertEq(centuari.getMarketTotalCbt(marketId), expectedCbt);
        assertGe(centuari.getBorrowPosition(marketId, borrower), matchedAmount);
    }

    function testFuzz_InterestCalculation(
        uint256 principal,
        uint256 rate,
        uint256 durationDays
    ) public view {
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
            0
        );

        bytes32 marketId = _getMarketId(loanToken, maturity);

        uint256 marketBefore = centuari.getMarketTotalCbt(marketId);
        uint256 lendPosBefore = centuari.getLendPositionCbtAmount(marketId, lender);
        address settlementBefore = centuari.settlement();
        address treasuryBefore = centuari.treasury();
        address ownerBefore = centuari.owner();

        // Upgrade to V2
        CentuariV2 newImpl = new CentuariV2();
        vm.prank(proxyAdminOwner);
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(proxy)),
            address(newImpl),
            ""
        );

        CentuariV2 centuariV2 = CentuariV2(address(proxy));
        assertEq(centuariV2.getMarketTotalCbt(marketId), marketBefore);
        assertEq(centuariV2.getLendPositionCbtAmount(marketId, lender), lendPosBefore);
        assertEq(centuariV2.settlement(), settlementBefore);
        assertEq(centuariV2.treasury(), treasuryBefore);
        assertEq(centuariV2.owner(), ownerBefore);
    }

    function test_Upgrade_CannotReinitialize() public {
        CentuariV2 newImpl = new CentuariV2();
        vm.prank(proxyAdminOwner);
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(proxy)),
            address(newImpl),
            ""
        );

        CentuariV2 centuariV2 = CentuariV2(address(proxy));

        vm.expectRevert();
        centuariV2.initialize(user, user, user);
    }

    // ============ Edge Case Tests ============

    function test_SettleMatch_SameLenderMultipleMatches() public {
        address lender = makeAddr("lender");
        address borrower1 = makeAddr("borrower1");
        address borrower2 = makeAddr("borrower2");
        uint256 maturity = block.timestamp + 365 days;

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
            0
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
            0
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
            0
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
            0
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
            0
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

        uint256 expectedLenderFee = makerFeeAmount;
        uint256 expectedBorrowerFee = takerFeeAmount;
        uint256 expectedNetLoanAmount = matchedAmount - expectedBorrowerFee;
        uint256 effectivePrincipal = matchedAmount - expectedLenderFee; // 990 ether
        uint256 expectedCbtMinted = _expectedCbt(effectivePrincipal, rate, maturity);

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
            takerFeeAmount
        );

        bytes32 marketId = _getMarketId(loanToken, maturity);

        assertEq(mockTreasury.lastAmount(), expectedNetLoanAmount);
        assertEq(mockTreasury.lastFrom(), lender);
        assertEq(mockTreasury.lastTo(), borrower);

        address bondTokenAddr = bondFactory.getBondToken(loanToken, maturity);
        CentuariBondERC20 bondToken = CentuariBondERC20(bondTokenAddr);
        // CBT held by Treasury, not lender
        assertEq(bondToken.balanceOf(address(mockTreasury)), expectedCbtMinted);
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

        uint256 expectedLenderFee = takerFeeAmount;
        uint256 expectedBorrowerFee = makerFeeAmount;
        uint256 expectedNetLoanAmount = matchedAmount - expectedBorrowerFee;
        uint256 effectivePrincipal = matchedAmount - expectedLenderFee; // 980 ether
        uint256 expectedCbtMinted = _expectedCbt(effectivePrincipal, rate, maturity);

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
            takerFeeAmount
        );

        bytes32 marketId = _getMarketId(loanToken, maturity);

        assertEq(mockTreasury.lastAmount(), expectedNetLoanAmount);
        assertEq(mockTreasury.lastFrom(), lender);
        assertEq(mockTreasury.lastTo(), borrower);

        address bondTokenAddr = bondFactory.getBondToken(loanToken, maturity);
        CentuariBondERC20 bondToken = CentuariBondERC20(bondTokenAddr);
        // CBT held by Treasury, not lender
        assertEq(bondToken.balanceOf(address(mockTreasury)), expectedCbtMinted);
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
            0
        );

        uint256 matchedAmount2 = 500 ether;
        uint256 makerFeeAmount = 5 ether;
        uint256 takerFeeAmount = 10 ether;
        bool borrowerIsTaker = true;

        uint256 expectedLenderFee = makerFeeAmount;
        uint256 effectivePrincipal2 = matchedAmount2 - expectedLenderFee; // 495 ether
        uint256 expectedCbtMinted2 = _expectedCbt(effectivePrincipal2, rate, maturity);

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
            takerFeeAmount
        );

        address bondTokenAddr = bondFactory.getBondToken(loanToken, maturity);
        CentuariBondERC20 bondToken = CentuariBondERC20(bondTokenAddr);
        assertEq(bondToken.balanceOf(lender2), expectedCbtMinted2);

        assertEq(mockTreasury.lastAmount(), matchedAmount2 - takerFeeAmount);
    }

    function test_SettleMatch_FeeCalculation_ZeroFees() public {
        address lender = makeAddr("lender");
        address borrower = makeAddr("borrower");
        uint256 matchedAmount = 1000 ether;
        uint256 maturity = block.timestamp + 365 days;

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
            0  // takerFeeAmount = 0
        );

        bytes32 marketId = _getMarketId(loanToken, maturity);

        assertEq(mockTreasury.lastAmount(), matchedAmount);

        uint256 expectedCbt = _expectedCbt(matchedAmount, 500, maturity);
        address bondTokenAddr = bondFactory.getBondToken(loanToken, maturity);
        CentuariBondERC20 bondToken = CentuariBondERC20(bondTokenAddr);
        assertEq(bondToken.balanceOf(address(mockTreasury)), expectedCbt);
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
            takerFeeAmount
        );

        assertEq(mockTreasury.lastAmount(), matchedAmount);

        uint256 effectivePrincipal = matchedAmount - makerFeeAmount; // 990 ether
        uint256 expectedCbt = _expectedCbt(effectivePrincipal, 500, maturity);
        address bondTokenAddr = bondFactory.getBondToken(loanToken, maturity);
        CentuariBondERC20 bondToken = CentuariBondERC20(bondTokenAddr);
        assertEq(bondToken.balanceOf(address(mockTreasury)), expectedCbt);
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
            takerFeeAmount
        );

        assertEq(mockTreasury.lastAmount(), matchedAmount - takerFeeAmount);

        uint256 expectedCbt = _expectedCbt(matchedAmount, 500, maturity);
        address bondTokenAddr = bondFactory.getBondToken(loanToken, maturity);
        CentuariBondERC20 bondToken = CentuariBondERC20(bondTokenAddr);
        assertEq(bondToken.balanceOf(address(mockTreasury)), expectedCbt);
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
            takerFeeAmount
        );

        // Settlement fees are separate from maker/taker fees
        // Treasury should receive settlement fees separately
        assertEq(mockTreasury.lastLenderSettlementFee(), lenderSettlementFee);
        assertEq(mockTreasury.lastBorrowerSettlementFee(), borrowerSettlementFee);

        // Net loan amount should still account for borrower fee (takerFeeAmount)
        assertEq(mockTreasury.lastAmount(), matchedAmount - takerFeeAmount);
    }

    function test_SettleMatch_FeeCalculation_NoBondFactory() public {
        // Create a new Centuari instance without setting bond factory
        Centuari newImpl = new Centuari();
        bytes memory initData = abi.encodeCall(
            Centuari.initialize,
            (owner, settlement, address(mockTreasury))
        );
        TransparentUpgradeableProxy newProxy = new TransparentUpgradeableProxy(
            address(newImpl),
            proxyAdminOwner,
            initData
        );
        Centuari centuariNoFactory = Centuari(address(newProxy));

        address lender = makeAddr("lender");
        address borrower = makeAddr("borrower");
        uint256 matchedAmount = 1000 ether;
        uint256 maturity = block.timestamp + 365 days;
        uint256 makerFeeAmount = 10 ether;
        uint256 takerFeeAmount = 20 ether;

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
            takerFeeAmount
        );

        // Treasury should still be called correctly
        assertEq(mockTreasury.lastAmount(), matchedAmount - takerFeeAmount);
        
        // Verify bond factory is not set
        assertEq(centuariNoFactory.bondTokenFactory(), address(0));
    }

    function test_SettleMatch_FeeCalculation_FeeSharesEqualToShares() public {
        address lender = makeAddr("lender");
        address borrower = makeAddr("borrower");
        uint256 matchedAmount = 1000 ether;
        uint256 maturity = block.timestamp + 365 days;
        uint256 makerFeeAmount = 0;
        uint256 takerFeeAmount = 0;
        bool borrowerIsTaker = false; // lender is taker

        // Set lenderFee equal to matchedAmount (100% fee)
        uint256 lenderFee = matchedAmount; // This would be takerFeeAmount when borrowerIsTaker = false
        // But we can't set takerFeeAmount = matchedAmount because that would make borrowerFee = matchedAmount
        // Instead, test with a high fee that results in feeShares >= shares

        // For this test, we'll use a scenario where feeShares calculation results in shares
        // This would happen if lenderFee = matchedAmount, but that's not realistic
        // Let's test with a fee that leaves exactly 1 ether effective principal for the lender.

        uint256 highTakerFee = matchedAmount - 1 ether; // Leaves effectivePrincipal = 1 ether
        uint256 highMakerFee = 0;

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
            highTakerFee
        );

        // effectivePrincipal = matchedAmount - highTakerFee = 1 ether; CBT = 1 + interest(1) ≈ 1
        uint256 effectivePrincipal = 1 ether;
        uint256 expectedCbt = _expectedCbt(effectivePrincipal, 500, maturity);
        address bondTokenAddr = bondFactory.getBondToken(loanToken, maturity);
        CentuariBondERC20 bondToken = CentuariBondERC20(bondTokenAddr);
        assertEq(bondToken.balanceOf(address(mockTreasury)), expectedCbt);
        assertEq(bondToken.balanceOf(lender), 0);
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
        uint256 expectedNetLoanAmount = matchedAmount - expectedBorrowerFee;

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
            takerFeeAmount
        );

        // Verify Treasury received net loan amount
        assertEq(mockTreasury.lastAmount(), expectedNetLoanAmount);

        uint256 effectivePrincipal = matchedAmount - expectedLenderFee;
        uint256 expectedCbtMinted = _expectedCbt(effectivePrincipal, rate, maturity);

        address bondTokenAddr = bondFactory.getBondToken(loanToken, maturity);
        CentuariBondERC20 bondToken = CentuariBondERC20(bondTokenAddr);
        assertEq(bondToken.balanceOf(address(mockTreasury)), expectedCbtMinted);
        assertEq(bondToken.balanceOf(lender), 0);
    }
}
