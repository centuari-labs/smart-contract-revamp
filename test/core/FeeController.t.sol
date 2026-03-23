// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {FeeController} from "../../src/core/FeeController.sol";
import {BalanceLedger} from "../../src/core/BalanceLedger.sol";
import {IFeeController} from "../../src/interfaces/IFeeController.sol";
import {ICentuariEndpoint} from "../../src/interfaces/ICentuariEndpoint.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract FeeControllerTest is Test {
    FeeController public feeController;
    BalanceLedger public ledger;

    address public owner = address(0x1);
    address public treasury = address(0x3);
    address public endpoint = address(0x4);
    address public lender = address(0x10);
    address public borrower = address(0x20);
    address public usdc = address(0x100);

    // Launch parameters
    uint256 public constant TAKER_FEE_BPS = 500;    // 5% of interest
    uint256 public constant MAKER_REBATE_BPS = 300;  // 3% of interest
    uint256 public constant ROLLOVER_FEE_BPS = 50;   // 0.5% of yield
    uint256 public constant SETTLEMENT_FEE = 100_000; // $0.10 at 6 decimals

    function setUp() public {
        // Deploy BalanceLedger
        ledger = BalanceLedger(address(new TransparentUpgradeableProxy(
            address(new BalanceLedger()), owner,
            abi.encodeCall(BalanceLedger.initialize, (owner))
        )));

        // Deploy FeeController
        feeController = FeeController(address(new TransparentUpgradeableProxy(
            address(new FeeController()), owner,
            abi.encodeCall(FeeController.initialize, (
                owner, address(ledger), treasury, endpoint,
                TAKER_FEE_BPS, MAKER_REBATE_BPS, ROLLOVER_FEE_BPS, SETTLEMENT_FEE
            ))
        )));

        // Authorize FeeController to write to BalanceLedger
        vm.startPrank(owner);
        ledger.setAuthorizedWriter(address(feeController), true);
        ledger.setAuthorizedWriter(address(this), true);
        vm.stopPrank();

        // Seed balances
        ledger.credit(lender, usdc, 100_000e6);
        ledger.credit(borrower, usdc, 100_000e6);
    }

    // ============ Initialization Tests ============

    function test_initialize_sets_parameters() public view {
        assertEq(feeController.takerFeeBPS(), TAKER_FEE_BPS);
        assertEq(feeController.makerRebateBPS(), MAKER_REBATE_BPS);
        assertEq(feeController.rolloverFeeBPS(), ROLLOVER_FEE_BPS);
        assertEq(feeController.settlementFeePerSide(), SETTLEMENT_FEE);
        assertEq(feeController.protocolTreasury(), treasury);
    }

    function test_validateFeeParams_reverts_taker_below_maker() public {
        // Test the invariant via governance: propose taker fee below maker rebate
        bytes32 paramId = keccak256("TAKER_FEE_BPS");
        vm.prank(owner);
        feeController.proposeFeeUpdate(paramId, 200); // Would be <= makerRebateBPS (300)

        vm.warp(block.timestamp + 48 hours + 1);

        vm.prank(owner);
        vm.expectRevert(IFeeController.TakerFeeMustExceedMakerRebate.selector);
        feeController.applyFeeUpdate(paramId);
    }

    // ============ computeMatchFees Tests ============

    function test_computeMatchFees_standard() public view {
        // 10,000 USDC at 8% for 30 days
        uint256 principal = 10_000e6;
        uint256 rateBPS = 800;
        uint256 matchTs = block.timestamp;
        uint256 maturity = block.timestamp + 30 days;
        uint256 elapsed = 30 days;

        uint256 grossInterest = (principal * rateBPS * elapsed) / (10_000 * 365 days);
        // grossInterest = 10_000_000_000 * 800 * 2592000 / (10000 * 31536000) = 65_753_424

        uint256 expectedTakerFee = (grossInterest * 500) / 10_000;   // 5% = 3_287_671
        uint256 expectedMakerRebate = (grossInterest * 300) / 10_000; // 3% = 1_972_602

        IFeeController.FeeDistribution memory dist = feeController.computeMatchFees(
            usdc, principal, rateBPS, matchTs, maturity, lender, borrower
        );

        assertEq(dist.operationType, 0); // MATCH

        // Verify borrower debit (taker fee + settlement fee)
        bool foundBorrowerDebit;
        for (uint256 i = 0; i < dist.transfers.length; i++) {
            if (dist.transfers[i].account == borrower && !dist.transfers[i].isCredit) {
                assertEq(dist.transfers[i].amount, expectedTakerFee + SETTLEMENT_FEE);
                foundBorrowerDebit = true;
            }
        }
        assertTrue(foundBorrowerDebit, "Borrower debit not found");

        // Verify lender credit (maker rebate - settlement fee)
        bool foundLenderCredit;
        for (uint256 i = 0; i < dist.transfers.length; i++) {
            if (dist.transfers[i].account == lender && dist.transfers[i].isCredit) {
                assertEq(dist.transfers[i].amount, expectedMakerRebate - SETTLEMENT_FEE);
                foundLenderCredit = true;
            }
        }
        assertTrue(foundLenderCredit, "Lender credit not found");

        // Verify protocol revenue
        uint256 expectedProtocol = expectedTakerFee - expectedMakerRebate + SETTLEMENT_FEE + SETTLEMENT_FEE;
        assertEq(dist.totalProtocolRevenue, expectedProtocol);
    }

    function test_computeMatchFees_zeroInterest() public view {
        // maturity == matchTimestamp → zero interest, but settlement fee still applies
        uint256 principal = 10_000e6;
        uint256 matchTs = block.timestamp;
        uint256 maturity = block.timestamp; // zero elapsed

        IFeeController.FeeDistribution memory dist = feeController.computeMatchFees(
            usdc, principal, 800, matchTs, maturity, lender, borrower
        );

        // With zero interest: takerFee=0, makerRebate=0
        // makerRebate (0) < settlementFee → lender settlement fee waived
        // Borrower pays: 0 + settlementFee
        // Protocol gets: 0 - 0 + 0 + settlementFee = settlementFee
        assertEq(dist.totalProtocolRevenue, SETTLEMENT_FEE);
    }

    function test_computeMatchFees_lowInterest_waivesLenderFee() public view {
        // Very short duration → interest < settlement fee
        // maker rebate will be less than settlement fee → waive lender fee
        uint256 principal = 10_000e6;
        uint256 matchTs = block.timestamp;
        uint256 maturity = block.timestamp + 1 hours; // very short

        uint256 grossInterest = (principal * 800 * 1 hours) / (10_000 * 365 days);
        uint256 makerRebate = (grossInterest * 300) / 10_000;

        IFeeController.FeeDistribution memory dist = feeController.computeMatchFees(
            usdc, principal, 800, matchTs, maturity, lender, borrower
        );

        // Verify lender fee waived (makerRebate < settlementFee)
        assertTrue(makerRebate < SETTLEMENT_FEE, "Pre-condition: rebate < settlement fee");

        // Lender should get a net credit of makerRebate (no settlement fee deduction)
        if (makerRebate > 0) {
            bool foundLenderCredit;
            for (uint256 i = 0; i < dist.transfers.length; i++) {
                if (dist.transfers[i].account == lender && dist.transfers[i].isCredit) {
                    assertEq(dist.transfers[i].amount, makerRebate);
                    foundLenderCredit = true;
                }
            }
            assertTrue(foundLenderCredit, "Lender should get maker rebate with no fee deduction");
        }
    }

    function test_computeRolloverFees() public view {
        uint256 yieldEarned = 1_000e6; // $1000 yield
        IFeeController.FeeDistribution memory dist = feeController.computeRolloverFees(
            usdc, yieldEarned, lender
        );

        uint256 expectedFee = (yieldEarned * 50) / 10_000; // 0.5% = 5e6
        assertEq(dist.totalProtocolRevenue, expectedFee);
        assertEq(dist.operationType, 1);
    }

    function test_computeRefinanceFees() public view {
        uint256 interestAccrued = 500e6; // $500 interest
        IFeeController.FeeDistribution memory dist = feeController.computeRefinanceFees(
            usdc, interestAccrued, borrower
        );

        uint256 expectedFee = (interestAccrued * 50) / 10_000; // 0.5% = 2.5e6 → rounds to 2_500_000
        assertEq(dist.totalProtocolRevenue, expectedFee);
        assertEq(dist.operationType, 2);
    }

    // ============ validateAndExecuteFees Tests ============

    function test_validateAndExecute_matchFees() public {
        uint256 principal = 10_000e6;
        uint256 rateBPS = 800;
        uint256 matchTs = block.timestamp;
        uint256 maturity = block.timestamp + 30 days;

        // Pre-compute fees
        IFeeController.FeeDistribution memory dist = feeController.computeMatchFees(
            usdc, principal, rateBPS, matchTs, maturity, lender, borrower
        );
        dist.operationId = keccak256("match-1");

        // Build arrays
        IFeeController.FeeDistribution[] memory distributions = new IFeeController.FeeDistribution[](1);
        distributions[0] = dist;

        ICentuariEndpoint.MatchedOrder[] memory matches = new ICentuariEndpoint.MatchedOrder[](1);
        matches[0] = ICentuariEndpoint.MatchedOrder({
            lender: lender,
            borrower: borrower,
            lendAsset: usdc,
            principal: principal,
            rateBPS: rateBPS,
            maturity: maturity,
            cbtMintAmount: principal + (principal * rateBPS * 30 days) / (10_000 * 365 days),
            matchTimestamp: matchTs,
            borrowerCollateralAssets: new address[](0),
            lendOrderId: keccak256("lend-1"),
            borrowOrderId: keccak256("borrow-1")
        });

        bytes memory operationData = abi.encode(
            matches,
            new ICentuariEndpoint.RolloverSettlement[](0),
            new ICentuariEndpoint.RefinanceSettlement[](0)
        );

        uint256 lenderBefore = ledger.getAvailable(lender, usdc);
        uint256 borrowerBefore = ledger.getAvailable(borrower, usdc);
        uint256 treasuryBefore = ledger.getAvailable(treasury, usdc);

        // Execute as endpoint
        vm.prank(endpoint);
        uint256 revenue = feeController.validateAndExecuteFees(distributions, operationData);

        uint256 lenderAfter = ledger.getAvailable(lender, usdc);
        uint256 borrowerAfter = ledger.getAvailable(borrower, usdc);
        uint256 treasuryAfter = ledger.getAvailable(treasury, usdc);

        // Verify revenue matches expected
        assertEq(revenue, dist.totalProtocolRevenue);

        // Verify borrower debited
        uint256 grossInterest = (principal * rateBPS * 30 days) / (10_000 * 365 days);
        uint256 expectedTakerFee = (grossInterest * 500) / 10_000;
        assertEq(borrowerBefore - borrowerAfter, expectedTakerFee + SETTLEMENT_FEE);

        // Verify treasury credited
        assertEq(treasuryAfter - treasuryBefore, dist.totalProtocolRevenue);

        // Verify lender got maker rebate minus settlement fee
        uint256 expectedMakerRebate = (grossInterest * 300) / 10_000;
        assertEq(lenderAfter - lenderBefore, expectedMakerRebate - SETTLEMENT_FEE);
    }

    function test_validateAndExecute_rejectsManipulatedFees() public {
        uint256 principal = 10_000e6;
        uint256 rateBPS = 800;
        uint256 matchTs = block.timestamp;
        uint256 maturity = block.timestamp + 30 days;

        // Compute correct fees then tamper
        IFeeController.FeeDistribution memory dist = feeController.computeMatchFees(
            usdc, principal, rateBPS, matchTs, maturity, lender, borrower
        );
        dist.operationId = keccak256("match-1");
        dist.totalProtocolRevenue = 999_999e6; // Manipulated!

        IFeeController.FeeDistribution[] memory distributions = new IFeeController.FeeDistribution[](1);
        distributions[0] = dist;

        ICentuariEndpoint.MatchedOrder[] memory matches = new ICentuariEndpoint.MatchedOrder[](1);
        matches[0] = ICentuariEndpoint.MatchedOrder({
            lender: lender,
            borrower: borrower,
            lendAsset: usdc,
            principal: principal,
            rateBPS: rateBPS,
            maturity: maturity,
            cbtMintAmount: principal + (principal * rateBPS * 30 days) / (10_000 * 365 days),
            matchTimestamp: matchTs,
            borrowerCollateralAssets: new address[](0),
            lendOrderId: keccak256("lend-1"),
            borrowOrderId: keccak256("borrow-1")
        });

        bytes memory operationData = abi.encode(
            matches,
            new ICentuariEndpoint.RolloverSettlement[](0),
            new ICentuariEndpoint.RefinanceSettlement[](0)
        );

        vm.prank(endpoint);
        vm.expectRevert(); // FeeMismatch
        feeController.validateAndExecuteFees(distributions, operationData);
    }

    function test_validateAndExecute_onlyEndpoint() public {
        IFeeController.FeeDistribution[] memory distributions = new IFeeController.FeeDistribution[](0);
        bytes memory operationData = abi.encode(
            new ICentuariEndpoint.MatchedOrder[](0),
            new ICentuariEndpoint.RolloverSettlement[](0),
            new ICentuariEndpoint.RefinanceSettlement[](0)
        );

        vm.prank(lender); // Not the endpoint
        vm.expectRevert(IFeeController.Unauthorized.selector);
        feeController.validateAndExecuteFees(distributions, operationData);
    }

    // ============ Governance Timelock Tests ============

    function test_proposeFeeUpdate_and_apply() public {
        bytes32 paramId = keccak256("TAKER_FEE_BPS");

        vm.prank(owner);
        feeController.proposeFeeUpdate(paramId, 600); // 6%

        // Cannot apply before timelock
        vm.prank(owner);
        vm.expectRevert(IFeeController.TimelockNotExpired.selector);
        feeController.applyFeeUpdate(paramId);

        // Warp past timelock
        vm.warp(block.timestamp + 48 hours + 1);

        vm.prank(owner);
        feeController.applyFeeUpdate(paramId);

        assertEq(feeController.takerFeeBPS(), 600);
    }

    function test_applyFeeUpdate_rejects_taker_below_maker() public {
        bytes32 paramId = keccak256("TAKER_FEE_BPS");

        vm.prank(owner);
        feeController.proposeFeeUpdate(paramId, 200); // Would be <= makerRebateBPS (300)

        vm.warp(block.timestamp + 48 hours + 1);

        vm.prank(owner);
        vm.expectRevert(IFeeController.TakerFeeMustExceedMakerRebate.selector);
        feeController.applyFeeUpdate(paramId);
    }

    function test_applyFeeUpdate_rejects_exceeds_max() public {
        bytes32 paramId = keccak256("TAKER_FEE_BPS");

        vm.prank(owner);
        feeController.proposeFeeUpdate(paramId, 2000); // > MAX_TAKER_FEE_BPS (1000)

        vm.warp(block.timestamp + 48 hours + 1);

        vm.prank(owner);
        vm.expectRevert(); // FeeExceedsMaximum
        feeController.applyFeeUpdate(paramId);
    }

    // ============ Pause Tests ============

    function test_pause_blocks_execution() public {
        vm.prank(owner);
        feeController.pause();

        IFeeController.FeeDistribution[] memory distributions = new IFeeController.FeeDistribution[](0);

        vm.prank(endpoint);
        vm.expectRevert(IFeeController.ContractPaused.selector);
        feeController.validateAndExecuteFees(distributions, "");
    }

    // ============ Fuzz Tests ============

    function testFuzz_computeMatchFees_noOverflow(
        uint256 principal,
        uint256 rateBPS,
        uint256 duration
    ) public view {
        principal = bound(principal, 1, 1_000_000_000e6); // up to $1B
        rateBPS = bound(rateBPS, 10, 10_000); // 0.1% to 100%
        duration = bound(duration, 1, 365 days);

        uint256 matchTs = block.timestamp;
        uint256 maturity = block.timestamp + duration;

        // Should not revert
        IFeeController.FeeDistribution memory dist = feeController.computeMatchFees(
            usdc, principal, rateBPS, matchTs, maturity, lender, borrower
        );

        // Protocol revenue must be >= 0 (implicit — uint256)
        // Taker fee > maker rebate invariant holds because BPS params enforce it
        assertTrue(dist.totalProtocolRevenue > 0 || duration == 0, "Protocol should earn revenue");
    }

    function testFuzz_matchFees_sumConservation(
        uint256 principal,
        uint256 rateBPS,
        uint256 duration
    ) public view {
        principal = bound(principal, 1_000e6, 100_000_000e6);
        rateBPS = bound(rateBPS, 100, 5000);
        duration = bound(duration, 1 days, 90 days);

        uint256 matchTs = block.timestamp;
        uint256 maturity = block.timestamp + duration;

        IFeeController.FeeDistribution memory dist = feeController.computeMatchFees(
            usdc, principal, rateBPS, matchTs, maturity, lender, borrower
        );

        // Sum all credits and debits — they must balance
        uint256 totalCredits;
        uint256 totalDebits;
        for (uint256 i = 0; i < dist.transfers.length; i++) {
            if (dist.transfers[i].isCredit) {
                totalCredits += dist.transfers[i].amount;
            } else {
                totalDebits += dist.transfers[i].amount;
            }
        }

        assertEq(totalDebits, totalCredits, "Fee transfers must be zero-sum");
    }
}
