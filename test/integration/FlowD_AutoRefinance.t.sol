// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CentuariEndpoint} from "../../src/core/CentuariEndpoint.sol";
import {BalanceLedger} from "../../src/core/BalanceLedger.sol";
import {CentuariBondERC20Factory} from "../../src/core/centuari/CentuariBondERC20Factory.sol";
import {ICentuariEndpoint} from "../../src/interfaces/ICentuariEndpoint.sol";
import {IFeeController} from "../../src/interfaces/IFeeController.sol";
import {MockToken} from "../../src/mocks/MockToken.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @title FlowD_AutoRefinance
/// @notice Integration test: borrow match -> maturity -> refinance with ADD_TO_LOAN
contract FlowD_AutoRefinanceTest is Test {
    using MessageHashUtils for bytes32;

    CentuariEndpoint public endpoint;
    BalanceLedger public ledger;
    CentuariBondERC20Factory public bondFactory;
    MockToken public usdc;

    address owner = address(0x1);
    address multisig = address(0x2);
    uint256 signerPk = 0xA11CE;
    address signer;
    address lender = address(0x10);
    address borrower = address(0x20);

    function setUp() public {
        signer = vm.addr(signerPk);
        usdc = new MockToken("USD Coin", "USDC", 6, 0);
        ledger = BalanceLedger(address(new TransparentUpgradeableProxy(
            address(new BalanceLedger()), owner,
            abi.encodeCall(BalanceLedger.initialize, (owner))
        )));
        endpoint = CentuariEndpoint(address(new TransparentUpgradeableProxy(
            address(new CentuariEndpoint()), owner,
            abi.encodeCall(CentuariEndpoint.initialize, (owner, signer, multisig, address(ledger)))
        )));
        bondFactory = new CentuariBondERC20Factory(address(endpoint));

        vm.warp(100000);
        vm.startPrank(owner);
        ledger.proposeAuthorizedWriter(address(endpoint), true);
        vm.warp(100000 + 48 hours + 1);
        ledger.applyAuthorizedWriter();
        ledger.proposeAuthorizedWriter(address(this), true);
        vm.warp(100000 + 96 hours + 2);
        ledger.applyAuthorizedWriter();
        endpoint.proposeAdminAddress("factory", address(bondFactory));
        vm.warp(100000 + 144 hours + 3);
        endpoint.applyAdminAddress("factory");
        vm.stopPrank();

        // Seed lender balance for the initial match
        usdc.mint(lender, 100_000e6);
        vm.startPrank(lender);
        usdc.approve(address(ledger), 100_000e6);
        ledger.deposit(address(usdc), 100_000e6);
        vm.stopPrank();
    }

    function _signBatch(ICentuariEndpoint.SettlementBatch memory batch) internal view returns (bytes memory) {
        bytes32 d = keccak256(abi.encode(batch.nonce, batch.timestamp,
            keccak256(abi.encode(batch.matches)), keccak256(abi.encode(batch.rollovers)),
            keccak256(abi.encode(batch.refinances)), keccak256(abi.encode(batch.liquidations)),
            keccak256(abi.encode(batch.returnSettlements)), keccak256(abi.encode(batch.graceStarts)),
            keccak256(abi.encode(batch.feeDistributions))));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, d.toEthSignedMessageHash());
        return abi.encodePacked(r, s, v);
    }

    function _emptyBatch(uint256 nonce) internal view returns (ICentuariEndpoint.SettlementBatch memory b) {
        b.nonce = nonce;
        b.timestamp = block.timestamp;
        b.matches = new ICentuariEndpoint.MatchedOrder[](0);
        b.rollovers = new ICentuariEndpoint.RolloverSettlement[](0);
        b.refinances = new ICentuariEndpoint.RefinanceSettlement[](0);
        b.liquidations = new ICentuariEndpoint.LiquidationSettlement[](0);
        b.returnSettlements = new ICentuariEndpoint.ReturnSettlement[](0);
        b.graceStarts = new ICentuariEndpoint.GracePeriodStart[](0);
        b.feeDistributions = new IFeeController.FeeDistribution[](0);
    }

    /// @notice Borrow 5,000 USDC at 8% -> maturity -> refinance with ADD_TO_LOAN
    function test_flowD_auto_refinance() public {
        uint256 principal = 5_000e6;
        uint256 matchTs = block.timestamp;
        uint256 maturity = block.timestamp + 30 days;
        uint256 cbtAmount = principal + (principal * 800 * 30 days) / (10000 * 365 days);

        // Batch 1: Initial match (lender lends to borrower)
        ICentuariEndpoint.SettlementBatch memory batch1 = _emptyBatch(1);
        batch1.matches = new ICentuariEndpoint.MatchedOrder[](1);
        batch1.matches[0] = ICentuariEndpoint.MatchedOrder({
            lender: lender, borrower: borrower, lendAsset: address(usdc),
            principal: principal, rateBPS: 800, maturity: maturity,
            cbtMintAmount: cbtAmount, matchTimestamp: matchTs,
            borrowerCollateralAssets: new address[](0),
            lendOrderId: bytes32(uint256(1)), borrowOrderId: bytes32(uint256(2))
        });
        endpoint.submitSettlementBatch(batch1, _signBatch(batch1));

        // Verify borrower received USDC
        assertEq(ledger.getAvailable(borrower, address(usdc)), principal);

        // Warp past maturity
        vm.warp(maturity + 1);

        // Batch 2: Refinance with ADD_TO_LOAN (interestMethod=0)
        // Interest = principal * 800 * 30days / (10000 * 365days)
        uint256 interest = (principal * 800 * 30 days) / (10000 * 365 days);
        uint256 newPrincipal = principal + interest;
        uint256 newMaturity = maturity + 31 days;

        ICentuariEndpoint.SettlementBatch memory batch2 = _emptyBatch(2);
        batch2.refinances = new ICentuariEndpoint.RefinanceSettlement[](1);
        batch2.refinances[0] = ICentuariEndpoint.RefinanceSettlement({
            borrower: borrower,
            oldPositionId: bytes32(uint256(100)),
            oldDebt: principal,
            interestAccrued: interest,
            interestMethod: 0, // ADD_TO_LOAN
            deductAsset: address(0),
            deductAmount: 0,
            newPrincipal: newPrincipal,
            newRateBPS: 850,
            newMaturity: newMaturity,
            refinanceCount: 1,
            lendAsset: address(usdc),
            anchorRateBPS: 850, // H-04 FIX: Must be non-zero (unconditional check now matches rollover)
            penaltyInterest: 0 // No grace period penalty in this test
        });

        endpoint.submitSettlementBatch(batch2, _signBatch(batch2));
        assertEq(endpoint.lastProcessedNonce(), 2, "Both batches processed");
    }
}
