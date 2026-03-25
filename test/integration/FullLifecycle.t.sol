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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @title FullLifecycle
/// @notice E2E test: deposit → engine match → CBT minted → warp past maturity → redeemCBT → USDC back
contract FullLifecycleTest is Test {
    using MessageHashUtils for bytes32;

    CentuariEndpoint public endpoint;
    BalanceLedger public ledger;
    CentuariBondERC20Factory public bondFactory;
    MockToken public usdc;

    address public owner = address(0x1);
    address public multisig = address(0x2);
    uint256 public signerPk = 0xA11CE;
    address public signer;
    address public lender = address(0x10);
    address public borrower = address(0x20);

    function setUp() public {
        signer = vm.addr(signerPk);

        // Deploy mock USDC with 6 decimals
        usdc = new MockToken("USD Coin", "USDC", 6, 0);

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

        // Deploy BondFactory — the endpoint is the MINTER for all CBTs
        bondFactory = new CentuariBondERC20Factory(address(endpoint));

        // Wire up with timelocks
        vm.warp(100000);
        vm.startPrank(owner);

        // Authorize endpoint as writer on ledger
        ledger.proposeAuthorizedWriter(address(endpoint), true);
        vm.warp(100000 + 48 hours + 1);
        ledger.applyAuthorizedWriter();

        // Authorize test contract for seeding balances
        ledger.proposeAuthorizedWriter(address(this), true);
        vm.warp(100000 + 96 hours + 2);
        ledger.applyAuthorizedWriter();

        // Set bond factory on endpoint via admin timelock
        endpoint.proposeAdminAddress("factory", address(bondFactory));
        vm.warp(100000 + 144 hours + 3);
        endpoint.applyAdminAddress("factory");

        vm.stopPrank();

        // Mint real USDC to lender and have them deposit into BalanceLedger
        // BalanceLedger.deposit() does safeTransferFrom — real tokens move in
        usdc.mint(lender, 100_000e6);
        vm.startPrank(lender);
        usdc.approve(address(ledger), 100_000e6);
        ledger.deposit(address(usdc), 100_000e6);
        vm.stopPrank();
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
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    function _expectedCBT(
        uint256 principal, uint256 rateBPS, uint256 matchTs, uint256 maturity
    ) internal pure returns (uint256) {
        uint256 elapsed = maturity - matchTs;
        uint256 interest = (principal * rateBPS * elapsed) / (10000 * 365 days);
        return principal + interest;
    }

    // ============ Full Lifecycle Test ============

    /// @notice E2E: deposit → match → CBT minted → warp past maturity → redeemCBT → USDC returned
    function test_fullLifecycle_deposit_match_redeem() public {
        // ── STEP 1: Verify lender has deposited ──
        assertEq(ledger.getAvailable(lender, address(usdc)), 100_000e6);
        assertEq(usdc.balanceOf(address(ledger)), 100_000e6);

        // ── STEP 2: Create and submit settlement batch with 1 match ──
        uint256 principal = 10_000e6; // 10,000 USDC
        uint256 rateBPS = 800;        // 8% APY
        uint256 matchTs = block.timestamp;
        uint256 maturity = block.timestamp + 30 days;
        uint256 cbtAmount = _expectedCBT(principal, rateBPS, matchTs, maturity);

        // Build match
        address[] memory collateralAssets = new address[](0);
        ICentuariEndpoint.MatchedOrder[] memory matches = new ICentuariEndpoint.MatchedOrder[](1);
        matches[0] = ICentuariEndpoint.MatchedOrder({
            lender: lender,
            borrower: borrower,
            lendAsset: address(usdc),
            principal: principal,
            rateBPS: rateBPS,
            maturity: maturity,
            cbtMintAmount: cbtAmount,
            matchTimestamp: matchTs,
            borrowerCollateralAssets: collateralAssets,
            lendOrderId: bytes32(uint256(1)),
            borrowOrderId: bytes32(uint256(2))
        });

        // Build empty batch arrays
        ICentuariEndpoint.SettlementBatch memory batch;
        batch.matches = matches;
        batch.rollovers = new ICentuariEndpoint.RolloverSettlement[](0);
        batch.refinances = new ICentuariEndpoint.RefinanceSettlement[](0);
        batch.liquidations = new ICentuariEndpoint.LiquidationSettlement[](0);
        batch.returnSettlements = new ICentuariEndpoint.ReturnSettlement[](0);
        batch.graceStarts = new ICentuariEndpoint.GracePeriodStart[](0);
        batch.feeDistributions = new IFeeController.FeeDistribution[](0);
        batch.nonce = 1;
        batch.timestamp = block.timestamp;

        // Sign and submit
        bytes memory sig = _signBatch(batch);
        endpoint.submitSettlementBatch(batch, sig);

        // ── STEP 3: Verify match results ──
        // Lender's available reduced by principal
        assertEq(ledger.getAvailable(lender, address(usdc)), 100_000e6 - principal);

        // Borrower credited principal
        assertEq(ledger.getAvailable(borrower, address(usdc)), principal);

        // CBT minted to lender
        address cbtAddress = bondFactory.getBondToken(address(usdc), maturity);
        assertTrue(cbtAddress != address(0), "CBT should be deployed");
        CentuariBondERC20 cbt = CentuariBondERC20(cbtAddress);
        assertEq(cbt.balanceOf(lender), cbtAmount, "Lender should have CBT");
        assertEq(cbt.LOAN_TOKEN(), address(usdc));
        assertEq(cbt.MATURITY(), maturity);

        // Nonce advanced
        assertEq(endpoint.lastProcessedNonce(), 1);

        // ── STEP 4: Warp past maturity ──
        vm.warp(maturity + 1);

        // ── STEP 5: Lender redeems CBT via CentuariEndpoint ──
        uint256 lenderUsdcBefore = usdc.balanceOf(lender);
        uint256 lenderCbtBefore = cbt.balanceOf(lender);

        vm.prank(lender);
        endpoint.redeemCBT(cbtAddress, cbtAmount);

        // ── STEP 6: Verify redemption ──
        // CBT burned
        assertEq(cbt.balanceOf(lender), 0, "CBT should be burned");
        // USDC transferred to lender (1:1 with CBT amount)
        assertEq(usdc.balanceOf(lender), lenderUsdcBefore + cbtAmount, "Lender should receive USDC");

        // Ledger USDC balance reduced
        assertLt(usdc.balanceOf(address(ledger)), 100_000e6, "Ledger balance should decrease");
    }

    /// @notice Verify direct CBT.redeem() is disabled (NC-01)
    function test_directCBTRedeem_reverts() public {
        // Create a CBT by submitting a match
        uint256 principal = 1000e6;
        uint256 maturity = block.timestamp + 30 days;
        uint256 cbtAmount = _expectedCBT(principal, 800, block.timestamp, maturity);

        address[] memory collateral = new address[](0);
        ICentuariEndpoint.MatchedOrder[] memory matches = new ICentuariEndpoint.MatchedOrder[](1);
        matches[0] = ICentuariEndpoint.MatchedOrder({
            lender: lender,
            borrower: borrower,
            lendAsset: address(usdc),
            principal: principal,
            rateBPS: 800,
            maturity: maturity,
            cbtMintAmount: cbtAmount,
            matchTimestamp: block.timestamp,
            borrowerCollateralAssets: collateral,
            lendOrderId: bytes32(uint256(10)),
            borrowOrderId: bytes32(uint256(20))
        });

        ICentuariEndpoint.SettlementBatch memory batch;
        batch.matches = matches;
        batch.rollovers = new ICentuariEndpoint.RolloverSettlement[](0);
        batch.refinances = new ICentuariEndpoint.RefinanceSettlement[](0);
        batch.liquidations = new ICentuariEndpoint.LiquidationSettlement[](0);
        batch.returnSettlements = new ICentuariEndpoint.ReturnSettlement[](0);
        batch.graceStarts = new ICentuariEndpoint.GracePeriodStart[](0);
        batch.feeDistributions = new IFeeController.FeeDistribution[](0);
        batch.nonce = 1;
        batch.timestamp = block.timestamp;
        endpoint.submitSettlementBatch(batch, _signBatch(batch));

        address cbtAddress = bondFactory.getBondToken(address(usdc), maturity);
        CentuariBondERC20 cbt = CentuariBondERC20(cbtAddress);

        // Warp past maturity
        vm.warp(maturity + 1);

        // Direct redeem should revert (NC-01 fix)
        vm.prank(lender);
        vm.expectRevert(CentuariBondERC20.UseEndpointRedeem.selector);
        cbt.redeem(cbtAmount);
    }
}
