// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CentuariEndpoint} from "../../src/core/CentuariEndpoint.sol";
import {BalanceLedger} from "../../src/core/BalanceLedger.sol";
import {ICentuariEndpoint} from "../../src/interfaces/ICentuariEndpoint.sol";
import {IFeeController} from "../../src/interfaces/IFeeController.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract CentuariEndpointTest is Test {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    CentuariEndpoint public endpoint;
    BalanceLedger public ledger;

    address public owner = address(0x1);
    address public multisig = address(0x2);
    uint256 public signerPrivateKey = 0xA11CE;
    address public signer;
    address public lender = address(0x10);
    address public borrower = address(0x20);
    address public usdc = address(0x100);

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

        // Authorize endpoint to write to ledger
        vm.warp(1000); // Start at a clean timestamp
        vm.startPrank(owner);
        ledger.proposeAuthorizedWriter(address(endpoint), true);
        vm.warp(1000 + 48 hours + 1);
        ledger.applyAuthorizedWriter();
        ledger.proposeAuthorizedWriter(address(this), true);
        vm.warp(1000 + 96 hours + 2);
        ledger.applyAuthorizedWriter();
        vm.stopPrank();
        ledger.credit(lender, usdc, 100_000e6);
    }

    // ============ Helpers ============

    function _signBatch(ICentuariEndpoint.SettlementBatch memory batch) internal view returns (bytes memory) {
        bytes32 batchDigest = keccak256(abi.encode(
            batch.nonce,
            batch.timestamp,
            keccak256(abi.encode(batch.matches)),
            keccak256(abi.encode(batch.rollovers)),
            keccak256(abi.encode(batch.refinances)),
            keccak256(abi.encode(batch.liquidations)),
            keccak256(abi.encode(batch.returnSettlements)),
            keccak256(abi.encode(batch.graceStarts)),
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

    function _batchWithMatch(uint256 nonce) internal view returns (ICentuariEndpoint.SettlementBatch memory batch) {
        batch = _emptyBatch(nonce);

        ICentuariEndpoint.MatchedOrder[] memory matches = new ICentuariEndpoint.MatchedOrder[](1);
        matches[0] = ICentuariEndpoint.MatchedOrder({
            lender: lender,
            borrower: borrower,
            lendAsset: usdc,
            principal: 10_000e6,
            rateBPS: 800,
            maturity: block.timestamp + 30 days,
            cbtMintAmount: _expectedCBT(10_000e6, 800, block.timestamp, block.timestamp + 30 days),
            matchTimestamp: block.timestamp,
            borrowerCollateralAssets: new address[](0),
            lendOrderId: keccak256("lend-1"),
            borrowOrderId: keccak256("borrow-1")
        });

        batch.matches = matches;
    }

    function _expectedCBT(uint256 principal, uint256 rateBPS, uint256 matchTs, uint256 maturity) internal pure returns (uint256) {
        uint256 elapsed = maturity - matchTs;
        uint256 interest = (principal * rateBPS * elapsed) / (10000 * 365 days);
        return principal + interest;
    }

    // ============ Signature Verification Tests (Security Invariant #1) ============

    function test_submitBatch_valid_signature() public {
        ICentuariEndpoint.SettlementBatch memory batch = _emptyBatch(1);
        bytes memory sig = _signBatch(batch);

        endpoint.submitSettlementBatch(batch, sig);

        assertEq(endpoint.lastProcessedNonce(), 1);
    }

    function test_submitBatch_invalid_signature_reverts() public {
        ICentuariEndpoint.SettlementBatch memory batch = _emptyBatch(1);

        // Sign with wrong key
        uint256 wrongKey = 0xBEEF;
        bytes32 batchDigest = keccak256(abi.encode(
            batch.nonce, batch.timestamp,
            keccak256(abi.encode(batch.matches)),
            keccak256(abi.encode(batch.rollovers)),
            keccak256(abi.encode(batch.refinances)),
            keccak256(abi.encode(batch.liquidations)),
            keccak256(abi.encode(batch.returnSettlements)),
            keccak256(abi.encode(batch.graceStarts)),
            keccak256(abi.encode(batch.feeDistributions))
        ));
        bytes32 ethSignedHash = batchDigest.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, ethSignedHash);
        bytes memory badSig = abi.encodePacked(r, s, v);

        vm.expectRevert(ICentuariEndpoint.InvalidSignature.selector);
        endpoint.submitSettlementBatch(batch, badSig);
    }

    // ============ Nonce Tests (Security Invariant #2) ============

    function test_nonce_strictly_increasing() public {
        // Nonce 1 succeeds
        ICentuariEndpoint.SettlementBatch memory batch1 = _emptyBatch(1);
        endpoint.submitSettlementBatch(batch1, _signBatch(batch1));
        assertEq(endpoint.lastProcessedNonce(), 1);

        // Nonce 2 succeeds
        ICentuariEndpoint.SettlementBatch memory batch2 = _emptyBatch(2);
        endpoint.submitSettlementBatch(batch2, _signBatch(batch2));
        assertEq(endpoint.lastProcessedNonce(), 2);
    }

    function test_nonce_replay_reverts() public {
        ICentuariEndpoint.SettlementBatch memory batch1 = _emptyBatch(1);
        endpoint.submitSettlementBatch(batch1, _signBatch(batch1));

        // Replay nonce 1
        ICentuariEndpoint.SettlementBatch memory replay = _emptyBatch(1);
        vm.expectRevert(abi.encodeWithSelector(ICentuariEndpoint.NonceTooLow.selector, 2, 1));
        endpoint.submitSettlementBatch(replay, _signBatch(replay));
    }

    function test_nonce_skip_reverts() public {
        // Skip nonce 1, submit nonce 2
        ICentuariEndpoint.SettlementBatch memory batch = _emptyBatch(2);
        vm.expectRevert(abi.encodeWithSelector(ICentuariEndpoint.NonceTooLow.selector, 1, 2));
        endpoint.submitSettlementBatch(batch, _signBatch(batch));
    }

    // ============ Timestamp Tests ============

    function test_timestamp_within_tolerance() public {
        ICentuariEndpoint.SettlementBatch memory batch = _emptyBatch(1);
        batch.timestamp = block.timestamp + 30; // 30 seconds ahead (within 60s tolerance)
        endpoint.submitSettlementBatch(batch, _signBatch(batch));
    }

    function test_timestamp_drift_reverts() public {
        ICentuariEndpoint.SettlementBatch memory batch = _emptyBatch(1);
        batch.timestamp = block.timestamp + 120; // 120 seconds ahead (exceeds 60s)

        vm.expectRevert(
            abi.encodeWithSelector(ICentuariEndpoint.TimestampDrift.selector, batch.timestamp, block.timestamp)
        );
        endpoint.submitSettlementBatch(batch, _signBatch(batch));
    }

    // ============ CBT Amount Validation ============

    function test_match_with_valid_cbt_amount() public {
        ICentuariEndpoint.SettlementBatch memory batch = _batchWithMatch(1);
        bytes memory sig = _signBatch(batch);

        endpoint.submitSettlementBatch(batch, sig);
        assertEq(endpoint.lastProcessedNonce(), 1);
    }

    function test_match_with_invalid_cbt_amount_reverts() public {
        ICentuariEndpoint.SettlementBatch memory batch = _batchWithMatch(1);
        // Corrupt the CBT amount
        batch.matches[0].cbtMintAmount = 999_999_999e6; // way off

        bytes memory sig = _signBatch(batch);

        vm.expectRevert(); // CBTMintMismatch
        endpoint.submitSettlementBatch(batch, sig);
    }

    // ============ Match Processing Tests ============

    function test_match_debits_lender_credits_borrower() public {
        uint256 lenderBefore = ledger.getAvailable(lender, usdc);

        ICentuariEndpoint.SettlementBatch memory batch = _batchWithMatch(1);
        endpoint.submitSettlementBatch(batch, _signBatch(batch));

        uint256 lenderAfter = ledger.getAvailable(lender, usdc);
        uint256 borrowerAfter = ledger.getAvailable(borrower, usdc);

        assertEq(lenderBefore - lenderAfter, 10_000e6);
        assertEq(borrowerAfter, 10_000e6);
    }

    // ============ Return Processing Tests ============

    function test_return_credits_lender() public {
        ICentuariEndpoint.SettlementBatch memory batch = _emptyBatch(1);
        ICentuariEndpoint.ReturnSettlement[] memory returns_ = new ICentuariEndpoint.ReturnSettlement[](1);
        returns_[0] = ICentuariEndpoint.ReturnSettlement({
            lender: lender,
            positionId: keccak256("pos-1"),
            asset: usdc,
            amount: 5_000e6
        });
        batch.returnSettlements = returns_;

        endpoint.submitSettlementBatch(batch, _signBatch(batch));

        // Lender gets 5000 credited on top of initial 100k
        assertEq(ledger.getAvailable(lender, usdc), 105_000e6);
    }

    // ============ Pause Tests ============

    function test_pause_by_multisig() public {
        vm.prank(multisig);
        endpoint.pause();
        assertTrue(endpoint.paused());
    }

    function test_pause_reverts_non_multisig() public {
        vm.prank(owner);
        vm.expectRevert(ICentuariEndpoint.Unauthorized.selector);
        endpoint.pause();
    }

    function test_paused_blocks_settlement() public {
        vm.prank(multisig);
        endpoint.pause();

        ICentuariEndpoint.SettlementBatch memory batch = _emptyBatch(1);
        vm.expectRevert(ICentuariEndpoint.ContractPaused.selector);
        endpoint.submitSettlementBatch(batch, _signBatch(batch));
    }

    function test_unpause_resumes() public {
        vm.prank(multisig);
        endpoint.pause();

        vm.prank(multisig);
        endpoint.unpause();

        ICentuariEndpoint.SettlementBatch memory batch = _emptyBatch(1);
        endpoint.submitSettlementBatch(batch, _signBatch(batch));
        assertEq(endpoint.lastProcessedNonce(), 1);
    }

    // ============ Engine Signer Update ============

    function test_updateEngineSigner() public {
        address newSigner = address(0xDEAD);

        // Propose new signer (starts 48h timelock)
        vm.prank(owner);
        endpoint.proposeEngineSigner(newSigner);

        // Warp past 48h timelock
        vm.warp(block.timestamp + 48 hours + 1);

        // Apply the proposed signer
        vm.prank(owner);
        endpoint.updateEngineSigner(newSigner);

        assertEq(endpoint.authorizedSigner(), newSigner);
    }

    function test_updateEngineSigner_reverts_non_owner() public {
        vm.prank(multisig);
        vm.expectRevert(); // OwnableUnauthorizedAccount
        endpoint.updateEngineSigner(address(0xDEAD));
    }

    // ============ Grace Period Tests ============

    function test_grace_period_recorded() public {
        ICentuariEndpoint.SettlementBatch memory batch = _emptyBatch(1);
        ICentuariEndpoint.GracePeriodStart[] memory graceStarts = new ICentuariEndpoint.GracePeriodStart[](1);
        graceStarts[0] = ICentuariEndpoint.GracePeriodStart({
            borrower: borrower,
            positionId: keccak256("pos-1"),
            reason: keccak256("HF_TOO_LOW"),
            gracePeriodEnds: block.timestamp + 6 hours
        });
        batch.graceStarts = graceStarts;

        endpoint.submitSettlementBatch(batch, _signBatch(batch));
        // Grace period event emitted (verified by non-revert)
    }
}
