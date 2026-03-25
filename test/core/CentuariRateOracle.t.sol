// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {CentuariRateOracle} from "../../src/core/CentuariRateOracle.sol";
import {ICentuariRateOracle} from "../../src/interfaces/ICentuariRateOracle.sol";

contract CentuariRateOracleTest is Test {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    CentuariRateOracle public oracle;

    address public owner = address(0x1);
    uint256 public signerPrivateKey = 0xA11CE;
    address public signer;

    // Test data
    address public usdc = address(0x100);
    uint256 public maturity = 1_750_000_000; // fixed future timestamp
    uint256 public nextMaturity = 1_752_678_400;

    function setUp() public {
        signer = vm.addr(signerPrivateKey);

        vm.warp(1_000_000); // start at a known timestamp

        oracle = CentuariRateOracle(
            address(
                new TransparentUpgradeableProxy(
                    address(new CentuariRateOracle()),
                    owner,
                    abi.encodeCall(CentuariRateOracle.initialize, (owner, signer))
                )
            )
        );
    }

    // ============ Helpers ============

    function _signRateSnapshot(
        address asset,
        uint256 mat,
        uint256 vwapBPS
    ) internal view returns (bytes memory) {
        // HIGH-4 FIX: digest now includes nonce for replay prevention
        uint256 nonce = oracle.getSnapshotNonce(asset, mat);
        bytes32 digest = keccak256(abi.encode("commitRateSnapshot", asset, mat, vwapBPS, nonce));
        bytes32 ethHash = digest.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, ethHash);
        return abi.encodePacked(r, s, v);
    }

    function _signAnchorRate(
        address asset,
        uint256 currentMat,
        uint256 nextMat,
        uint256 anchorRateBPS,
        uint8 computationMethod,
        uint256 computedAt
    ) internal view returns (bytes memory) {
        bytes32 digest = keccak256(
            abi.encode(
                "commitAnchorRate",
                asset,
                currentMat,
                nextMat,
                anchorRateBPS,
                computationMethod,
                computedAt
            )
        );
        bytes32 ethHash = digest.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, ethHash);
        return abi.encodePacked(r, s, v);
    }

    // ============ Test 1: commitRateSnapshot — valid signature ============

    function test_commitRateSnapshot_valid() public {
        uint256 vwapBPS = 850;
        bytes memory sig = _signRateSnapshot(usdc, maturity, vwapBPS);

        vm.expectEmit(true, true, false, true);
        emit ICentuariRateOracle.RateSnapshotCommitted(usdc, maturity, vwapBPS, block.timestamp);

        oracle.commitRateSnapshot(usdc, maturity, vwapBPS, sig);

        (uint256 rate, uint256 committedAt) = oracle.getRate(usdc, maturity);
        assertEq(rate, vwapBPS);
        assertEq(committedAt, block.timestamp);
    }

    // ============ Test 2: commitRateSnapshot — invalid sig reverts ============

    function test_commitRateSnapshot_invalid_sig_reverts() public {
        uint256 vwapBPS = 850;
        uint256 wrongKey = 0xBEEF;

        bytes32 digest = keccak256(abi.encode("commitRateSnapshot", usdc, maturity, vwapBPS, block.timestamp));
        bytes32 ethHash = digest.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, ethHash);
        bytes memory badSig = abi.encodePacked(r, s, v);

        vm.expectRevert(ICentuariRateOracle.InvalidSignature.selector);
        oracle.commitRateSnapshot(usdc, maturity, vwapBPS, badSig);
    }

    // ============ Test 3: commitAnchorRate — succeeds ============

    function test_commitAnchorRate_succeeds() public {
        uint256 anchorRateBPS = 794;
        uint8 computationMethod = 0; // VWAP
        uint256 computedAt = block.timestamp;

        bytes memory sig = _signAnchorRate(usdc, maturity, nextMaturity, anchorRateBPS, computationMethod, computedAt);

        vm.expectEmit(true, true, false, true);
        emit ICentuariRateOracle.AnchorRateCommitted(usdc, maturity, nextMaturity, anchorRateBPS, computationMethod);

        oracle.commitAnchorRate(usdc, maturity, nextMaturity, anchorRateBPS, computationMethod, computedAt, sig);

        uint256 stored = oracle.getAnchorRate(usdc, maturity, nextMaturity);
        assertEq(stored, anchorRateBPS);
    }

    // ============ Test 4: commitAnchorRate — immutable, cannot overwrite ============

    function test_commitAnchorRate_immutable() public {
        uint256 anchorRateBPS = 794;
        uint8 method = 0;
        uint256 computedAt = block.timestamp;

        bytes memory sig1 = _signAnchorRate(usdc, maturity, nextMaturity, anchorRateBPS, method, computedAt);
        oracle.commitAnchorRate(usdc, maturity, nextMaturity, anchorRateBPS, method, computedAt, sig1);

        // Attempt to overwrite — must revert
        uint256 newRate = 900;
        bytes memory sig2 = _signAnchorRate(usdc, maturity, nextMaturity, newRate, method, computedAt);

        vm.expectRevert(
            abi.encodeWithSelector(
                ICentuariRateOracle.AnchorRateAlreadyCommitted.selector,
                usdc,
                maturity,
                nextMaturity
            )
        );
        oracle.commitAnchorRate(usdc, maturity, nextMaturity, newRate, method, computedAt, sig2);

        // Original value unchanged
        assertEq(oracle.getAnchorRate(usdc, maturity, nextMaturity), anchorRateBPS);
    }

    // ============ Test 5: getRate — returns committed values ============

    function test_getRate_returns_committed() public {
        uint256 vwapBPS = 720;
        bytes memory sig = _signRateSnapshot(usdc, maturity, vwapBPS);
        oracle.commitRateSnapshot(usdc, maturity, vwapBPS, sig);

        (uint256 rate, uint256 committedAt) = oracle.getRate(usdc, maturity);
        assertEq(rate, vwapBPS);
        assertEq(committedAt, block.timestamp);
    }

    function test_getRate_reverts_when_not_found() public {
        vm.expectRevert(abi.encodeWithSelector(ICentuariRateOracle.RateNotFound.selector, usdc, maturity));
        oracle.getRate(usdc, maturity);
    }

    // ============ Test 6: isRateFresh — true within maxStaleSeconds ============

    function test_isRateFresh_true() public {
        bytes memory sig = _signRateSnapshot(usdc, maturity, 800);
        oracle.commitRateSnapshot(usdc, maturity, 800, sig);

        // Still fresh immediately
        bool fresh = oracle.isRateFresh(usdc, maturity, 300);
        assertTrue(fresh);

        // Still fresh just before the deadline
        vm.warp(block.timestamp + 299);
        assertTrue(oracle.isRateFresh(usdc, maturity, 300));
    }

    // ============ Test 7: isRateFresh — false beyond maxStaleSeconds ============

    function test_isRateFresh_false() public {
        bytes memory sig = _signRateSnapshot(usdc, maturity, 800);
        oracle.commitRateSnapshot(usdc, maturity, 800, sig);

        uint256 maxStale = 300;
        vm.warp(block.timestamp + maxStale + 1);

        assertFalse(oracle.isRateFresh(usdc, maturity, maxStale));
    }

    function test_isRateFresh_false_when_never_committed() public {
        assertFalse(oracle.isRateFresh(usdc, maturity, 300));
    }

    // ============ Test 8: getActiveMaturities ============

    function test_getActiveMaturities() public {
        uint256[] memory mats = new uint256[](3);
        mats[0] = 1_750_000_000;
        mats[1] = 1_752_678_400;
        mats[2] = 1_755_356_800;

        vm.prank(owner);
        oracle.setActiveMaturities(usdc, mats);

        uint256[] memory result = oracle.getActiveMaturities(usdc);
        assertEq(result.length, 3);
        assertEq(result[0], mats[0]);
        assertEq(result[1], mats[1]);
        assertEq(result[2], mats[2]);
    }

    function test_getActiveMaturities_empty_by_default() public view {
        uint256[] memory result = oracle.getActiveMaturities(usdc);
        assertEq(result.length, 0);
    }

    // ============ Test 9: proposeOracleSigner — cannot apply before 48h ============

    function test_proposeOracleSigner_timelock() public {
        address newSigner = address(0xDEAD);

        vm.prank(owner);
        oracle.proposeOracleSigner(newSigner);

        // Warp to just before the deadline
        vm.warp(block.timestamp + 48 hours - 1);

        vm.prank(owner);
        vm.expectRevert("CentuariRateOracle: timelock not expired");
        oracle.applyOracleSigner();
    }

    function test_proposeOracleSigner_reverts_zero_address() public {
        vm.prank(owner);
        vm.expectRevert(ICentuariRateOracle.ZeroAddress.selector);
        oracle.proposeOracleSigner(address(0));
    }

    function test_proposeOracleSigner_reverts_non_owner() public {
        vm.prank(address(0x999));
        vm.expectRevert();
        oracle.proposeOracleSigner(address(0xDEAD));
    }

    // ============ Test 10: applyOracleSigner — works after 48h ============

    function test_applyOracleSigner() public {
        address newSigner = address(0xDEAD);

        vm.prank(owner);
        oracle.proposeOracleSigner(newSigner);

        vm.warp(block.timestamp + 48 hours + 1);

        vm.prank(owner);
        oracle.applyOracleSigner();

        // Verify: new signer can commit, old signer cannot
        uint256 vwapBPS = 900;
        // Sign with newSigner (private key unknown here; we test indirectly via old key rejection)
        bytes memory oldSig = _signRateSnapshot(usdc, maturity, vwapBPS);
        vm.expectRevert(ICentuariRateOracle.InvalidSignature.selector);
        oracle.commitRateSnapshot(usdc, maturity, vwapBPS, oldSig);
    }

    function test_applyOracleSigner_new_signer_can_commit() public {
        uint256 newSignerKey = 0xBEEFCAFE;
        address newSigner = vm.addr(newSignerKey);

        vm.prank(owner);
        oracle.proposeOracleSigner(newSigner);

        vm.warp(block.timestamp + 48 hours + 1);

        vm.prank(owner);
        oracle.applyOracleSigner();

        // Sign with the new key
        uint256 vwapBPS = 900;
        bytes32 digest = keccak256(abi.encode("commitRateSnapshot", usdc, maturity, vwapBPS, block.timestamp));
        bytes32 ethHash = digest.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(newSignerKey, ethHash);
        bytes memory newSig = abi.encodePacked(r, s, v);

        oracle.commitRateSnapshot(usdc, maturity, vwapBPS, newSig);

        (uint256 rate,) = oracle.getRate(usdc, maturity);
        assertEq(rate, vwapBPS);
    }

    // ============ Test: cancelOracleSigner ============

    function test_cancelOracleSigner_clears_pending() public {
        address newSigner = address(0xDEAD);

        vm.prank(owner);
        oracle.proposeOracleSigner(newSigner);

        vm.prank(owner);
        oracle.cancelOracleSigner();

        vm.warp(block.timestamp + 48 hours + 1);

        // Apply should fail — no pending signer
        vm.prank(owner);
        vm.expectRevert("CentuariRateOracle: no pending signer");
        oracle.applyOracleSigner();
    }

    // ============ Test: applyOracleSigner reverts when no pending ============

    function test_applyOracleSigner_reverts_no_pending() public {
        vm.prank(owner);
        vm.expectRevert("CentuariRateOracle: no pending signer");
        oracle.applyOracleSigner();
    }

    // ============ Fuzz: commitRateSnapshot round-trip ============

    function testFuzz_commitRateSnapshot_roundtrip(uint256 vwapBPS) public {
        vwapBPS = bound(vwapBPS, 10, 10_000);

        bytes memory sig = _signRateSnapshot(usdc, maturity, vwapBPS);
        oracle.commitRateSnapshot(usdc, maturity, vwapBPS, sig);

        (uint256 rate, uint256 committedAt) = oracle.getRate(usdc, maturity);
        assertEq(rate, vwapBPS);
        assertEq(committedAt, block.timestamp);
        assertTrue(oracle.isRateFresh(usdc, maturity, 1));
    }

    // ============ Test: getRatesForAsset ============

    function test_getRatesForAsset() public {
        uint256[] memory mats = new uint256[](2);
        mats[0] = maturity;
        mats[1] = nextMaturity;

        vm.prank(owner);
        oracle.setActiveMaturities(usdc, mats);

        bytes memory sig1 = _signRateSnapshot(usdc, maturity, 800);
        oracle.commitRateSnapshot(usdc, maturity, 800, sig1);

        // Advance time so second snapshot has different timestamp
        vm.warp(block.timestamp + 10);

        bytes memory sig2 = _signRateSnapshot(usdc, nextMaturity, 820);
        oracle.commitRateSnapshot(usdc, nextMaturity, 820, sig2);

        (uint256[] memory retMats, uint256[] memory rates, uint256[] memory committedAts) =
            oracle.getRatesForAsset(usdc);

        assertEq(retMats.length, 2);
        assertEq(rates[0], 800);
        assertEq(rates[1], 820);
        assertGt(committedAts[0], 0);
        assertGt(committedAts[1], 0);
    }

    // ============ Test: setActiveMaturities — only owner ============

    function test_setActiveMaturities_reverts_non_owner() public {
        uint256[] memory mats = new uint256[](1);
        mats[0] = maturity;

        vm.prank(address(0x999));
        vm.expectRevert();
        oracle.setActiveMaturities(usdc, mats);
    }

    // ============ Test: updateSigner DEPRECATED reverts ============

    function test_updateSigner_deprecated_reverts() public {
        vm.prank(owner);
        vm.expectRevert("CentuariRateOracle: use proposeOracleSigner");
        oracle.updateSigner(address(0xDEAD));
    }
}
