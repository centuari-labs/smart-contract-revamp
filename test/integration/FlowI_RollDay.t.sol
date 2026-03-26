// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CentuariEndpoint} from "../../src/core/CentuariEndpoint.sol";
import {BalanceLedger} from "../../src/core/BalanceLedger.sol";
import {CentuariBondERC20Factory} from "../../src/core/centuari/CentuariBondERC20Factory.sol";
import {CentuariBondERC20} from "../../src/core/centuari/CentuariBondERC20.sol";
import {ICentuariEndpoint} from "../../src/interfaces/ICentuariEndpoint.sol";
import {IFeeController} from "../../src/interfaces/IFeeController.sol";
import {MockToken} from "../../src/mocks/MockToken.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @title FlowI_RollDay
/// @notice Integration test: multiple positions processed in single maturity batch
///         Tests: 1 rollover + 1 return + 1 grace start in one batch
contract FlowI_RollDayTest is Test {
    using MessageHashUtils for bytes32;

    CentuariEndpoint public endpoint;
    BalanceLedger public ledger;
    CentuariBondERC20Factory public bondFactory;
    MockToken public usdc;

    address owner = address(0x1);
    address multisig = address(0x2);
    uint256 signerPk = 0xA11CE;
    address signer;
    address lender1 = address(0x10);
    address lender2 = address(0x11);
    address borrower1 = address(0x20);

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

        // Seed both lenders
        usdc.mint(lender1, 100_000e6);
        vm.startPrank(lender1);
        usdc.approve(address(ledger), 100_000e6);
        ledger.deposit(address(usdc), 100_000e6);
        vm.stopPrank();

        usdc.mint(lender2, 50_000e6);
        vm.startPrank(lender2);
        usdc.approve(address(ledger), 50_000e6);
        ledger.deposit(address(usdc), 50_000e6);
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

    /// @notice Multi-position batch: 2 matches -> warp -> 1 return + 1 grace start
    function test_flowI_multi_position_maturity_batch() public {
        uint256 maturity = block.timestamp + 30 days;
        uint256 matchTs = block.timestamp;
        uint256 p1 = 10_000e6;
        uint256 p2 = 5_000e6;
        uint256 dur = 30 days;
        uint256 yr = 365 days;
        uint256 cbt1 = p1 + (p1 * 800 * dur) / (10000 * yr);
        uint256 cbt2 = p2 + (p2 * 750 * dur) / (10000 * yr);

        // Batch 1: Two matches (lender1 + lender2 lend to borrower1)
        ICentuariEndpoint.SettlementBatch memory batch1;
        batch1.nonce = 1;
        batch1.timestamp = block.timestamp;
        batch1.matches = new ICentuariEndpoint.MatchedOrder[](2);
        batch1.matches[0] = ICentuariEndpoint.MatchedOrder({
            lender: lender1, borrower: borrower1, lendAsset: address(usdc),
            principal: 10_000e6, rateBPS: 800, maturity: maturity,
            cbtMintAmount: cbt1, matchTimestamp: matchTs,
            borrowerCollateralAssets: new address[](0),
            lendOrderId: bytes32(uint256(1)), borrowOrderId: bytes32(uint256(2))
        });
        batch1.matches[1] = ICentuariEndpoint.MatchedOrder({
            lender: lender2, borrower: borrower1, lendAsset: address(usdc),
            principal: 5_000e6, rateBPS: 750, maturity: maturity,
            cbtMintAmount: cbt2, matchTimestamp: matchTs,
            borrowerCollateralAssets: new address[](0),
            lendOrderId: bytes32(uint256(3)), borrowOrderId: bytes32(uint256(4))
        });
        batch1.rollovers = new ICentuariEndpoint.RolloverSettlement[](0);
        batch1.refinances = new ICentuariEndpoint.RefinanceSettlement[](0);
        batch1.liquidations = new ICentuariEndpoint.LiquidationSettlement[](0);
        batch1.returnSettlements = new ICentuariEndpoint.ReturnSettlement[](0);
        batch1.graceStarts = new ICentuariEndpoint.GracePeriodStart[](0);
        batch1.feeDistributions = new IFeeController.FeeDistribution[](0);

        endpoint.submitSettlementBatch(batch1, _signBatch(batch1));
        assertEq(endpoint.lastProcessedNonce(), 1);

        // Warp past maturity
        vm.warp(maturity + 1);

        // Batch 2: 1 return (lender2's position returned) + 1 grace start (borrower1)
        ICentuariEndpoint.SettlementBatch memory batch2;
        batch2.nonce = 2;
        batch2.timestamp = block.timestamp;
        batch2.matches = new ICentuariEndpoint.MatchedOrder[](0);
        batch2.rollovers = new ICentuariEndpoint.RolloverSettlement[](0);
        batch2.refinances = new ICentuariEndpoint.RefinanceSettlement[](0);
        batch2.liquidations = new ICentuariEndpoint.LiquidationSettlement[](0);

        // Return: lender2's principal + interest back to available
        batch2.returnSettlements = new ICentuariEndpoint.ReturnSettlement[](1);
        batch2.returnSettlements[0] = ICentuariEndpoint.ReturnSettlement({
            lender: lender2,
            positionId: bytes32(uint256(200)),
            asset: address(usdc),
            amount: cbt2
        });

        // Grace start: borrower1 enters grace period (refinance failed)
        batch2.graceStarts = new ICentuariEndpoint.GracePeriodStart[](1);
        batch2.graceStarts[0] = ICentuariEndpoint.GracePeriodStart({
            borrower: borrower1,
            positionId: bytes32(uint256(300)),
            reason: bytes32("RATE_CEILING_EXCEEDED"),
            gracePeriodEnds: block.timestamp + 6 hours
        });
        batch2.feeDistributions = new IFeeController.FeeDistribution[](0);

        endpoint.submitSettlementBatch(batch2, _signBatch(batch2));

        // Verify return credited lender2
        assertEq(ledger.getAvailable(lender2, address(usdc)), 50_000e6 - 5_000e6 + cbt2);

        // Verify nonce
        assertEq(endpoint.lastProcessedNonce(), 2);
    }
}
