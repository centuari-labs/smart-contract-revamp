// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {Settlement} from "../../src/settlement/Settlement.sol";
import {ISettlement} from "../../src/interfaces/ISettlement.sol";
import {ICentuari} from "../../src/interfaces/ICentuari.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title MockCentuari
/// @notice Mock contract for testing Settlement
contract MockCentuari is ICentuari {
    // Track calls for assertions
    uint256 public settleMatchCallCount;
    bytes32 public lastMatchId;
    address public lastLender;
    address public lastBorrower;
    uint256 public lastMatchedAmount;

    bool public shouldRevert;

    function setRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function settleMatch(
        bytes32 matchId,
        address lender,
        bytes32, // lendOrderId
        address borrower,
        bytes32, // borrowOrderId
        address, // loanToken
        uint256 matchedAmount,
        uint256, // rate
        uint256 // maturity
    ) external override {
        if (shouldRevert) {
            revert("MockCentuari: forced revert");
        }

        settleMatchCallCount++;
        lastMatchId = matchId;
        lastLender = lender;
        lastBorrower = borrower;
        lastMatchedAmount = matchedAmount;
    }

    function reset() external {
        settleMatchCallCount = 0;
        lastMatchId = bytes32(0);
        lastLender = address(0);
        lastBorrower = address(0);
        lastMatchedAmount = 0;
        shouldRevert = false;
    }
}

/// @title SettlementTest
/// @notice Test suite for Settlement contract
contract SettlementTest is Test {
    Settlement public implementation;
    Settlement public settlement;
    MockCentuari public mockCentuari;

    address public owner;
    address public operator;
    address public user;
    address public loanToken;

    // Events to test
    event MatchSettled(
        bytes32 indexed matchId,
        bytes32 indexed lendOrderId,
        bytes32 indexed borrowOrderId,
        address lender,
        address borrower,
        address loanToken,
        uint256 matchedAmount,
        uint256 rate,
        uint256 maturity
    );

    event BatchSettlementCompleted(uint256 matchCount, uint256 totalVolume);
    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);
    event CentuariUpdated(address indexed oldCentuari, address indexed newCentuari);
    event Paused(address account);
    event Unpaused(address account);

    function setUp() public {
        owner = makeAddr("owner");
        operator = makeAddr("operator");
        user = makeAddr("user");
        loanToken = makeAddr("loanToken");

        // Deploy mock Centuari
        mockCentuari = new MockCentuari();

        // Deploy implementation
        implementation = new Settlement();

        // Deploy proxy
        bytes memory initData = abi.encodeCall(
            Settlement.initialize,
            (owner, operator, address(mockCentuari))
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        settlement = Settlement(address(proxy));
    }

    // ============ Helper Functions ============

    function _createMatchData(
        bytes32 matchId,
        address lender,
        address borrower,
        uint256 amount
    ) internal view returns (ISettlement.MatchData memory) {
        return ISettlement.MatchData({
            matchId: matchId,
            lendOrderId: keccak256(abi.encodePacked("lend", matchId)),
            lender: lender,
            borrowOrderId: keccak256(abi.encodePacked("borrow", matchId)),
            borrower: borrower,
            matchedAmount: amount,
            rate: 500, // 5%
            loanToken: loanToken,
            maturity: block.timestamp + 30 days
        });
    }

    // ============ Initialization Tests ============

    function test_Initialize() public view {
        assertEq(settlement.owner(), owner);
        assertEq(settlement.operator(), operator);
        assertEq(settlement.centuari(), address(mockCentuari));
        assertEq(settlement.paused(), false);
    }

    function test_Initialize_RevertZeroOwner() public {
        Settlement newImpl = new Settlement();
        bytes memory initData = abi.encodeCall(
            Settlement.initialize,
            (address(0), operator, address(mockCentuari))
        );
        vm.expectRevert(ISettlement.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_Initialize_RevertZeroOperator() public {
        Settlement newImpl = new Settlement();
        bytes memory initData = abi.encodeCall(
            Settlement.initialize,
            (owner, address(0), address(mockCentuari))
        );
        vm.expectRevert(ISettlement.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_Initialize_RevertZeroCentuari() public {
        Settlement newImpl = new Settlement();
        bytes memory initData = abi.encodeCall(
            Settlement.initialize,
            (owner, operator, address(0))
        );
        vm.expectRevert(ISettlement.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    // ============ settleMatch Tests ============

    function test_SettleMatch_Success() public {
        ISettlement.MatchData memory matchData = _createMatchData(
            bytes32(uint256(1)),
            makeAddr("lender"),
            makeAddr("borrower"),
            1000 ether
        );

        vm.prank(operator);
        vm.expectEmit(true, true, true, true);
        emit MatchSettled(
            matchData.matchId,
            matchData.lendOrderId,
            matchData.borrowOrderId,
            matchData.lender,
            matchData.borrower,
            matchData.loanToken,
            matchData.matchedAmount,
            matchData.rate,
            matchData.maturity
        );
        settlement.settleMatch(matchData);

        assertTrue(settlement.isSettled(matchData.matchId));
        assertEq(mockCentuari.settleMatchCallCount(), 1);
        assertEq(mockCentuari.lastMatchId(), matchData.matchId);
    }

    function test_SettleMatch_RevertUnauthorized() public {
        ISettlement.MatchData memory matchData = _createMatchData(
            bytes32(uint256(1)),
            makeAddr("lender"),
            makeAddr("borrower"),
            1000 ether
        );

        vm.prank(user);
        vm.expectRevert(ISettlement.Unauthorized.selector);
        settlement.settleMatch(matchData);
    }

    function test_SettleMatch_RevertWhenPaused() public {
        vm.prank(owner);
        settlement.pause();

        ISettlement.MatchData memory matchData = _createMatchData(
            bytes32(uint256(1)),
            makeAddr("lender"),
            makeAddr("borrower"),
            1000 ether
        );

        vm.prank(operator);
        vm.expectRevert(ISettlement.ContractPaused.selector);
        settlement.settleMatch(matchData);
    }

    function test_SettleMatch_RevertAlreadySettled() public {
        ISettlement.MatchData memory matchData = _createMatchData(
            bytes32(uint256(1)),
            makeAddr("lender"),
            makeAddr("borrower"),
            1000 ether
        );

        vm.prank(operator);
        settlement.settleMatch(matchData);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ISettlement.AlreadySettled.selector, matchData.matchId));
        settlement.settleMatch(matchData);
    }

    function test_SettleMatch_RevertInvalidMatchData_ZeroMatchId() public {
        ISettlement.MatchData memory matchData = _createMatchData(
            bytes32(0),
            makeAddr("lender"),
            makeAddr("borrower"),
            1000 ether
        );

        vm.prank(operator);
        vm.expectRevert(ISettlement.InvalidMatchData.selector);
        settlement.settleMatch(matchData);
    }

    function test_SettleMatch_RevertInvalidMatchData_ZeroLender() public {
        ISettlement.MatchData memory matchData = _createMatchData(
            bytes32(uint256(1)),
            address(0),
            makeAddr("borrower"),
            1000 ether
        );

        vm.prank(operator);
        vm.expectRevert(ISettlement.InvalidMatchData.selector);
        settlement.settleMatch(matchData);
    }

    function test_SettleMatch_RevertInvalidMatchData_ZeroBorrower() public {
        ISettlement.MatchData memory matchData = _createMatchData(
            bytes32(uint256(1)),
            makeAddr("lender"),
            address(0),
            1000 ether
        );

        vm.prank(operator);
        vm.expectRevert(ISettlement.InvalidMatchData.selector);
        settlement.settleMatch(matchData);
    }

    function test_SettleMatch_RevertInvalidMatchData_SameLenderBorrower() public {
        address same = makeAddr("same");
        ISettlement.MatchData memory matchData = _createMatchData(
            bytes32(uint256(1)),
            same,
            same,
            1000 ether
        );

        vm.prank(operator);
        vm.expectRevert(ISettlement.InvalidMatchData.selector);
        settlement.settleMatch(matchData);
    }

    function test_SettleMatch_RevertInvalidMatchData_ZeroAmount() public {
        ISettlement.MatchData memory matchData = _createMatchData(
            bytes32(uint256(1)),
            makeAddr("lender"),
            makeAddr("borrower"),
            0
        );

        vm.prank(operator);
        vm.expectRevert(ISettlement.InvalidMatchData.selector);
        settlement.settleMatch(matchData);
    }

    // ============ settleMatches (Batch) Tests ============

    function test_SettleMatches_Success() public {
        ISettlement.MatchData[] memory matches = new ISettlement.MatchData[](3);
        uint256 totalVolume;

        for (uint256 i; i < 3; i++) {
            matches[i] = _createMatchData(
                bytes32(uint256(i + 1)),
                makeAddr(string(abi.encodePacked("lender", i))),
                makeAddr(string(abi.encodePacked("borrower", i))),
                (i + 1) * 100 ether
            );
            totalVolume += matches[i].matchedAmount;
        }

        vm.prank(operator);
        vm.expectEmit(true, true, true, true);
        emit BatchSettlementCompleted(3, totalVolume);
        settlement.settleMatches(matches);

        for (uint256 i; i < 3; i++) {
            assertTrue(settlement.isSettled(matches[i].matchId));
        }
        assertEq(mockCentuari.settleMatchCallCount(), 3);
    }

    function test_SettleMatches_RevertEmptyBatch() public {
        ISettlement.MatchData[] memory matches = new ISettlement.MatchData[](0);

        vm.prank(operator);
        vm.expectRevert(ISettlement.EmptyBatch.selector);
        settlement.settleMatches(matches);
    }

    function test_SettleMatches_RevertOnDuplicateInBatch() public {
        ISettlement.MatchData[] memory matches = new ISettlement.MatchData[](2);
        matches[0] = _createMatchData(
            bytes32(uint256(1)),
            makeAddr("lender1"),
            makeAddr("borrower1"),
            100 ether
        );
        matches[1] = _createMatchData(
            bytes32(uint256(1)), // Same matchId
            makeAddr("lender2"),
            makeAddr("borrower2"),
            200 ether
        );

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ISettlement.AlreadySettled.selector, bytes32(uint256(1))));
        settlement.settleMatches(matches);
    }

    // ============ Administrative Functions Tests ============

    function test_SetOperator() public {
        address newOperator = makeAddr("newOperator");

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit OperatorUpdated(operator, newOperator);
        settlement.setOperator(newOperator);

        assertEq(settlement.operator(), newOperator);
    }

    function test_SetOperator_RevertNotOwner() public {
        vm.prank(user);
        vm.expectRevert();
        settlement.setOperator(makeAddr("newOperator"));
    }

    function test_SetOperator_RevertZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(ISettlement.ZeroAddress.selector);
        settlement.setOperator(address(0));
    }

    function test_SetCentuari() public {
        address newCentuari = makeAddr("newCentuari");

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit CentuariUpdated(address(mockCentuari), newCentuari);
        settlement.setCentuari(newCentuari);

        assertEq(settlement.centuari(), newCentuari);
    }

    function test_SetCentuari_RevertNotOwner() public {
        vm.prank(user);
        vm.expectRevert();
        settlement.setCentuari(makeAddr("newCentuari"));
    }

    function test_SetCentuari_RevertZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(ISettlement.ZeroAddress.selector);
        settlement.setCentuari(address(0));
    }

    function test_Pause() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit Paused(owner);
        settlement.pause();

        assertTrue(settlement.paused());
    }

    function test_Pause_RevertNotOwner() public {
        vm.prank(user);
        vm.expectRevert();
        settlement.pause();
    }

    function test_Unpause() public {
        vm.prank(owner);
        settlement.pause();

        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit Unpaused(owner);
        settlement.unpause();

        assertFalse(settlement.paused());
    }

    function test_Unpause_RevertNotOwner() public {
        vm.prank(owner);
        settlement.pause();

        vm.prank(user);
        vm.expectRevert();
        settlement.unpause();
    }

    // ============ View Functions Tests ============

    function test_IsSettled_ReturnsFalseForUnknown() public view {
        assertFalse(settlement.isSettled(bytes32(uint256(999))));
    }

    // ============ Fuzz Tests ============

    function testFuzz_SettleMatch(
        bytes32 matchId,
        address lender,
        address borrower,
        uint256 amount
    ) public {
        vm.assume(matchId != bytes32(0));
        vm.assume(lender != address(0));
        vm.assume(borrower != address(0));
        vm.assume(lender != borrower);
        vm.assume(amount > 0);

        ISettlement.MatchData memory matchData = ISettlement.MatchData({
            matchId: matchId,
            lendOrderId: keccak256(abi.encodePacked("lend", matchId)),
            lender: lender,
            borrowOrderId: keccak256(abi.encodePacked("borrow", matchId)),
            borrower: borrower,
            matchedAmount: amount,
            rate: 500,
            loanToken: loanToken,
            maturity: block.timestamp + 30 days
        });

        vm.prank(operator);
        settlement.settleMatch(matchData);

        assertTrue(settlement.isSettled(matchId));
    }
}
