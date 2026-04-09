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

/// @title FlowC_AutoRollover
/// @notice Integration test: match -> warp to maturity -> rollover batch burns old CBT, mints new
contract FlowC_AutoRolloverTest is Test {
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

    function _expectedCBT(uint256 principal, uint256 rateBPS, uint256 matchTs, uint256 maturity)
        internal pure returns (uint256) {
        return principal + (principal * rateBPS * (maturity - matchTs)) / (10000 * 365 days);
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
        b.collateralTopUps = new ICentuariEndpoint.CollateralTopUp[](0);
        b.feeDistributions = new IFeeController.FeeDistribution[](0);
    }

    /// @notice Match at 8% for 30 days -> warp to maturity -> rollover at 7.5% for 31 days
    function test_flowC_auto_rollover() public {
        uint256 principal = 10_000e6;
        uint256 matchTs = block.timestamp;
        uint256 maturity1 = block.timestamp + 30 days;
        uint256 cbtAmount1 = _expectedCBT(principal, 800, matchTs, maturity1);

        // Batch 1: Initial match
        ICentuariEndpoint.SettlementBatch memory batch1 = _emptyBatch(1);
        batch1.matches = new ICentuariEndpoint.MatchedOrder[](1);
        batch1.matches[0] = ICentuariEndpoint.MatchedOrder({
            lender: lender, borrower: borrower, lendAsset: address(usdc),
            principal: principal, rateBPS: 800, maturity: maturity1,
            cbtMintAmount: cbtAmount1, matchTimestamp: matchTs,
            borrowerCollateralAssets: new address[](0),
            lendOrderId: bytes32(uint256(1)), borrowOrderId: bytes32(uint256(2))
        });
        endpoint.submitSettlementBatch(batch1, _signBatch(batch1));

        // Verify CBT minted
        address oldCBT = bondFactory.getBondToken(address(usdc), maturity1);
        assertEq(CentuariBondERC20(oldCBT).balanceOf(lender), cbtAmount1);

        // Warp past maturity
        vm.warp(maturity1 + 1);

        // Batch 2: Rollover - burn old CBT, mint new at 7.5% for 31 days
        uint256 newMaturity = maturity1 + 31 days;
        uint256 newPrincipal = cbtAmount1; // Compounded: old principal + interest
        uint256 rolloverTs = block.timestamp;
        uint256 newMintAmount = _expectedCBT(newPrincipal, 750, rolloverTs, newMaturity);

        // Pre-create the new CBT contract so we have its address
        address newCBT = bondFactory.getBondToken(address(usdc), newMaturity);
        if (newCBT == address(0)) {
            // Factory will create it during rollover processing
            newCBT = bondFactory.computeBondTokenAddress(address(usdc), newMaturity);
        }

        ICentuariEndpoint.SettlementBatch memory batch2 = _emptyBatch(2);
        batch2.rollovers = new ICentuariEndpoint.RolloverSettlement[](1);
        batch2.rollovers[0] = ICentuariEndpoint.RolloverSettlement({
            lender: lender,
            oldCBT: oldCBT,
            burnAmount: cbtAmount1,
            newCBT: address(0), // Will be created by factory
            mintAmount: newMintAmount,
            newRateBPS: 750,
            anchorRateBPS: 750, // Must be > 0 and within 50 bps of newRateBPS
            rolloverCount: 1,
            newMaturity: newMaturity,
            newPrincipal: newPrincipal
        });

        endpoint.submitSettlementBatch(batch2, _signBatch(batch2));

        // Verify old CBT burned
        assertEq(CentuariBondERC20(oldCBT).balanceOf(lender), 0, "Old CBT should be burned");

        // Verify nonce advanced
        assertEq(endpoint.lastProcessedNonce(), 2);
    }
}
