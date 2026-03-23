// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CentuariEndpoint} from "../../src/core/CentuariEndpoint.sol";
import {BalanceLedger} from "../../src/core/BalanceLedger.sol";
import {FeeController} from "../../src/core/FeeController.sol";
import {ICentuariEndpoint} from "../../src/interfaces/ICentuariEndpoint.sol";
import {IFeeController} from "../../src/interfaces/IFeeController.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @title FeeIntegrationTest
/// @notice End-to-end integration test: CentuariEndpoint → FeeController → BalanceLedger
contract FeeIntegrationTest is Test {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    CentuariEndpoint public endpoint;
    BalanceLedger public ledger;
    FeeController public feeController;

    address public owner = address(0x1);
    address public multisig = address(0x2);
    address public treasury = address(0x3);
    uint256 public signerPrivateKey = 0xA11CE;
    address public signer;
    address public lender = address(0x10);
    address public borrower = address(0x20);
    address public usdc = address(0x100);

    uint256 public constant TAKER_FEE_BPS = 500;
    uint256 public constant MAKER_REBATE_BPS = 300;
    uint256 public constant ROLLOVER_FEE_BPS = 50;
    uint256 public constant SETTLEMENT_FEE = 100_000; // $0.10

    function setUp() public {
        signer = vm.addr(signerPrivateKey);

        // Deploy BalanceLedger
        ledger = BalanceLedger(address(new TransparentUpgradeableProxy(
            address(new BalanceLedger()), owner,
            abi.encodeCall(BalanceLedger.initialize, (owner))
        )));

        // Deploy CentuariEndpoint
        endpoint = CentuariEndpoint(address(new TransparentUpgradeableProxy(
            address(new CentuariEndpoint()), owner,
            abi.encodeCall(CentuariEndpoint.initialize, (owner, signer, multisig, address(ledger)))
        )));

        // Deploy FeeController
        feeController = FeeController(address(new TransparentUpgradeableProxy(
            address(new FeeController()), owner,
            abi.encodeCall(FeeController.initialize, (
                owner, address(ledger), treasury, address(endpoint),
                TAKER_FEE_BPS, MAKER_REBATE_BPS, ROLLOVER_FEE_BPS, SETTLEMENT_FEE
            ))
        )));

        // Wire up
        vm.startPrank(owner);
        ledger.setAuthorizedWriter(address(endpoint), true);
        ledger.setAuthorizedWriter(address(feeController), true);
        ledger.setAuthorizedWriter(address(this), true);
        endpoint.setFeeController(address(feeController));
        vm.stopPrank();

        // Seed balances
        ledger.credit(lender, usdc, 100_000e6);
        ledger.credit(borrower, usdc, 100_000e6);
    }

    // ============ Helpers ============

    function _signBatch(ICentuariEndpoint.SettlementBatch memory batch) internal view returns (bytes memory) {
        bytes32 batchDigest = keccak256(abi.encode(
            batch.nonce,
            batch.timestamp,
            batch.batchHash,
            batch.matches.length,
            batch.rollovers.length,
            batch.refinances.length,
            batch.liquidations.length,
            batch.returnSettlements.length,
            batch.graceStarts.length,
            keccak256(abi.encode(batch.feeDistributions))
        ));

        bytes32 ethSignedHash = batchDigest.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    function _emptyBatch(uint256 nonce) internal view returns (ICentuariEndpoint.SettlementBatch memory batch) {
        batch.nonce = nonce;
        batch.timestamp = block.timestamp;
        batch.batchHash = keccak256("test-batch");
        batch.matches = new ICentuariEndpoint.MatchedOrder[](0);
        batch.rollovers = new ICentuariEndpoint.RolloverSettlement[](0);
        batch.refinances = new ICentuariEndpoint.RefinanceSettlement[](0);
        batch.liquidations = new ICentuariEndpoint.LiquidationSettlement[](0);
        batch.returnSettlements = new ICentuariEndpoint.ReturnSettlement[](0);
        batch.graceStarts = new ICentuariEndpoint.GracePeriodStart[](0);
        batch.feeDistributions = new IFeeController.FeeDistribution[](0);
    }

    function _computeInterest(uint256 principal, uint256 rateBPS, uint256 elapsed) internal pure returns (uint256) {
        return (principal * rateBPS * elapsed) / (10_000 * 365 days);
    }

    // ============ Integration: Full Match with Fees ============

    function test_fullMatch_withFees() public {
        uint256 principal = 10_000e6;
        uint256 rateBPS = 800;
        uint256 matchTs = block.timestamp;
        uint256 maturity = block.timestamp + 30 days;
        uint256 elapsed = 30 days;

        uint256 grossInterest = _computeInterest(principal, rateBPS, elapsed);
        uint256 cbtAmount = principal + grossInterest;

        // Pre-compute fees via FeeController view
        IFeeController.FeeDistribution memory feeDist = feeController.computeMatchFees(
            usdc, principal, rateBPS, matchTs, maturity, lender, borrower
        );
        feeDist.operationId = keccak256("match-1");

        // Build batch
        ICentuariEndpoint.SettlementBatch memory batch = _emptyBatch(1);

        ICentuariEndpoint.MatchedOrder[] memory matches = new ICentuariEndpoint.MatchedOrder[](1);
        matches[0] = ICentuariEndpoint.MatchedOrder({
            lender: lender,
            borrower: borrower,
            lendAsset: usdc,
            principal: principal,
            rateBPS: rateBPS,
            maturity: maturity,
            cbtMintAmount: cbtAmount,
            matchTimestamp: matchTs,
            borrowerCollateralAssets: new address[](0),
            lendOrderId: keccak256("lend-1"),
            borrowOrderId: keccak256("borrow-1")
        });
        batch.matches = matches;

        IFeeController.FeeDistribution[] memory feeDistributions = new IFeeController.FeeDistribution[](1);
        feeDistributions[0] = feeDist;
        batch.feeDistributions = feeDistributions;

        // Record balances before
        uint256 lenderBefore = ledger.getAvailable(lender, usdc);
        uint256 borrowerBefore = ledger.getAvailable(borrower, usdc);
        uint256 treasuryBefore = ledger.getAvailable(treasury, usdc);

        // Submit batch
        endpoint.submitSettlementBatch(batch, _signBatch(batch));

        // Verify settlement + fees
        uint256 lenderAfter = ledger.getAvailable(lender, usdc);
        uint256 borrowerAfter = ledger.getAvailable(borrower, usdc);
        uint256 treasuryAfter = ledger.getAvailable(treasury, usdc);

        // Lender: debited principal, credited maker rebate - settlement fee
        uint256 expectedTakerFee = (grossInterest * TAKER_FEE_BPS) / 10_000;
        uint256 expectedMakerRebate = (grossInterest * MAKER_REBATE_BPS) / 10_000;
        uint256 lenderNetFeeCredit = expectedMakerRebate - SETTLEMENT_FEE;
        assertEq(lenderBefore - lenderAfter, principal - lenderNetFeeCredit, "Lender net debit");

        // Borrower: credited principal, debited taker fee + settlement fee
        uint256 borrowerFeeDebit = expectedTakerFee + SETTLEMENT_FEE;
        assertEq(borrowerAfter - borrowerBefore, principal - borrowerFeeDebit, "Borrower net credit");

        // Treasury: received protocol revenue
        uint256 expectedProtocol = expectedTakerFee - expectedMakerRebate + SETTLEMENT_FEE + SETTLEMENT_FEE;
        assertEq(treasuryAfter - treasuryBefore, expectedProtocol, "Treasury revenue");

        // Nonce advanced
        assertEq(endpoint.lastProcessedNonce(), 1);
    }

    // ============ Integration: Batch without fee controller (backward compat) ============

    function test_batchWithoutFeeController_noFees() public {
        // Remove fee controller
        vm.prank(owner);
        endpoint.setFeeController(address(0));

        ICentuariEndpoint.SettlementBatch memory batch = _emptyBatch(1);
        endpoint.submitSettlementBatch(batch, _signBatch(batch));
        assertEq(endpoint.lastProcessedNonce(), 1);
    }

    // ============ Integration: Empty fee distributions (no-op) ============

    function test_emptyFeeDistributions_succeeds() public {
        ICentuariEndpoint.SettlementBatch memory batch = _emptyBatch(1);
        // feeDistributions is already empty
        endpoint.submitSettlementBatch(batch, _signBatch(batch));
        assertEq(endpoint.lastProcessedNonce(), 1);
    }

    // ============ Integration: Fees included in signature ============

    function test_tamperedFees_invalidSignature() public {
        uint256 principal = 10_000e6;
        uint256 rateBPS = 800;
        uint256 matchTs = block.timestamp;
        uint256 maturity = block.timestamp + 30 days;

        IFeeController.FeeDistribution memory feeDist = feeController.computeMatchFees(
            usdc, principal, rateBPS, matchTs, maturity, lender, borrower
        );
        feeDist.operationId = keccak256("match-1");

        // Build and sign batch with correct fees
        ICentuariEndpoint.SettlementBatch memory batch = _emptyBatch(1);
        ICentuariEndpoint.MatchedOrder[] memory matches = new ICentuariEndpoint.MatchedOrder[](1);
        matches[0] = ICentuariEndpoint.MatchedOrder({
            lender: lender,
            borrower: borrower,
            lendAsset: usdc,
            principal: principal,
            rateBPS: rateBPS,
            maturity: maturity,
            cbtMintAmount: principal + _computeInterest(principal, rateBPS, 30 days),
            matchTimestamp: matchTs,
            borrowerCollateralAssets: new address[](0),
            lendOrderId: keccak256("lend-1"),
            borrowOrderId: keccak256("borrow-1")
        });
        batch.matches = matches;

        IFeeController.FeeDistribution[] memory feeDistributions = new IFeeController.FeeDistribution[](1);
        feeDistributions[0] = feeDist;
        batch.feeDistributions = feeDistributions;

        bytes memory sig = _signBatch(batch);

        // Now tamper with fees after signing
        batch.feeDistributions[0].totalProtocolRevenue = 999e6;

        // Signature won't match because feeDistributions hash changed
        vm.expectRevert(ICentuariEndpoint.InvalidSignature.selector);
        endpoint.submitSettlementBatch(batch, sig);
    }

    // ============ Integration: Multiple matches with fees ============

    function test_multipleMatches_withFees() public {
        uint256 matchTs = block.timestamp;
        uint256 maturity = block.timestamp + 30 days;

        ICentuariEndpoint.SettlementBatch memory batch = _emptyBatch(1);

        // Create 3 matches
        ICentuariEndpoint.MatchedOrder[] memory matches = new ICentuariEndpoint.MatchedOrder[](3);
        IFeeController.FeeDistribution[] memory feeDists = new IFeeController.FeeDistribution[](3);

        uint256[3] memory principals = [uint256(5_000e6), uint256(10_000e6), uint256(20_000e6)];
        uint256[3] memory rates = [uint256(600), uint256(800), uint256(1000)];

        for (uint256 i = 0; i < 3; i++) {
            uint256 interest = _computeInterest(principals[i], rates[i], 30 days);

            matches[i] = ICentuariEndpoint.MatchedOrder({
                lender: lender,
                borrower: borrower,
                lendAsset: usdc,
                principal: principals[i],
                rateBPS: rates[i],
                maturity: maturity,
                cbtMintAmount: principals[i] + interest,
                matchTimestamp: matchTs,
                borrowerCollateralAssets: new address[](0),
                lendOrderId: keccak256(abi.encode("lend", i)),
                borrowOrderId: keccak256(abi.encode("borrow", i))
            });

            feeDists[i] = feeController.computeMatchFees(
                usdc, principals[i], rates[i], matchTs, maturity, lender, borrower
            );
            feeDists[i].operationId = keccak256(abi.encode("match", i));
        }

        batch.matches = matches;
        batch.feeDistributions = feeDists;

        uint256 treasuryBefore = ledger.getAvailable(treasury, usdc);

        endpoint.submitSettlementBatch(batch, _signBatch(batch));

        uint256 treasuryAfter = ledger.getAvailable(treasury, usdc);

        // Treasury should have accumulated revenue from all 3 matches
        uint256 totalExpectedRevenue;
        for (uint256 i = 0; i < 3; i++) {
            totalExpectedRevenue += feeDists[i].totalProtocolRevenue;
        }
        assertEq(treasuryAfter - treasuryBefore, totalExpectedRevenue, "Total protocol revenue");
        assertEq(endpoint.lastProcessedNonce(), 1);
    }
}
