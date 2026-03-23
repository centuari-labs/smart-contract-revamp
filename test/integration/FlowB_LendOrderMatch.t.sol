// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {BalanceLedger} from "../../src/core/BalanceLedger.sol";
import {CentuariEndpoint} from "../../src/core/CentuariEndpoint.sol";
import {ICentuariEndpoint} from "../../src/interfaces/ICentuariEndpoint.sol";
import {IFeeController} from "../../src/interfaces/IFeeController.sol";
import {IBalanceLedger} from "../../src/interfaces/IBalanceLedger.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @title FlowB_LendOrderMatch
/// @notice Integration test for Flow B: Lend Order Placement and Match (Section 12.2)
///         Deposit → Lock → Match → CBT Mint → BalanceLedger Update
contract FlowB_LendOrderMatchTest is Test {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    BalanceLedger public ledger;
    CentuariEndpoint public endpoint;

    address public owner = address(0x1);
    address public multisig = address(0x2);
    uint256 public signerKey = 0xA11CE;
    address public signer;

    address public lender = address(0x10);
    address public borrower = address(0x20);
    address public usdc = address(0x100);

    uint256 public maturity;

    function setUp() public {
        signer = vm.addr(signerKey);
        maturity = block.timestamp + 30 days;

        ledger = BalanceLedger(address(new TransparentUpgradeableProxy(
            address(new BalanceLedger()), owner,
            abi.encodeCall(BalanceLedger.initialize, (owner))
        )));

        endpoint = CentuariEndpoint(address(new TransparentUpgradeableProxy(
            address(new CentuariEndpoint()), owner,
            abi.encodeCall(CentuariEndpoint.initialize, (owner, signer, multisig, address(ledger)))
        )));

        vm.startPrank(owner);
        ledger.setAuthorizedWriter(address(endpoint), true);
        ledger.setAuthorizedWriter(address(this), true); // for test setup
        vm.stopPrank();
    }

    /// @notice Full Flow B: deposit → lock → engine match → settlement → balance update
    function test_flowB_lend_order_match_e2e() public {
        // STEP 1: User deposits 10,000 USDC (simulated by crediting BalanceLedger)
        ledger.credit(lender, usdc, 10_000e6);
        assertEq(ledger.getAvailable(lender, usdc), 10_000e6);

        // STEP 2: Engine locks funds for order (TOCTOU fix)
        ledger.lockForOrder(lender, usdc, 10_000e6);
        assertEq(ledger.getAvailable(lender, usdc), 0);
        assertEq(ledger.getLocked(lender, usdc), 10_000e6);

        // STEP 3: Engine matches lend against borrow (off-chain)
        // STEP 4: Engine submits settlement batch

        uint256 principal = 10_000e6;
        uint256 rateBPS = 800; // 8% APY
        uint256 elapsed = 30 days;
        uint256 interest = (principal * rateBPS * elapsed) / (10000 * 365 days);
        uint256 cbtAmount = principal + interest;

        // First unlock (the endpoint will debit from available)
        ledger.unlockFromOrder(lender, usdc, principal);

        ICentuariEndpoint.SettlementBatch memory batch;
        batch.nonce = 1;
        batch.timestamp = block.timestamp;
        batch.batchHash = keccak256("flow-b-test");

        ICentuariEndpoint.MatchedOrder[] memory matches = new ICentuariEndpoint.MatchedOrder[](1);
        matches[0] = ICentuariEndpoint.MatchedOrder({
            lender: lender,
            borrower: borrower,
            lendAsset: usdc,
            principal: principal,
            rateBPS: rateBPS,
            maturity: maturity,
            cbtMintAmount: cbtAmount,
            matchTimestamp: block.timestamp,
            borrowerCollateralAssets: new address[](0),
            lendOrderId: keccak256("lend-1"),
            borrowOrderId: keccak256("borrow-1")
        });
        batch.matches = matches;
        batch.rollovers = new ICentuariEndpoint.RolloverSettlement[](0);
        batch.refinances = new ICentuariEndpoint.RefinanceSettlement[](0);
        batch.liquidations = new ICentuariEndpoint.LiquidationSettlement[](0);
        batch.returnSettlements = new ICentuariEndpoint.ReturnSettlement[](0);
        batch.graceStarts = new ICentuariEndpoint.GracePeriodStart[](0);
        batch.feeDistributions = new IFeeController.FeeDistribution[](0);

        // Sign batch (C-01 FIX: hash operation contents, not lengths)
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
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, ethSignedHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        // Submit settlement batch
        endpoint.submitSettlementBatch(batch, sig);

        // STEP 5: Verify results
        // Lender's USDC debited
        assertEq(ledger.getAvailable(lender, usdc), 0);

        // Borrower credited
        assertEq(ledger.getAvailable(borrower, usdc), principal);

        // Nonce advanced
        assertEq(endpoint.lastProcessedNonce(), 1);
    }
}
