// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {ICentuariRateOracle} from "../interfaces/ICentuariRateOracle.sol";
import {CentuariRateOracleStorage} from "./CentuariRateOracleStorage.sol";

/// @title CentuariRateOracle
/// @notice On-chain rate feed for external protocol integration
/// @dev Engine commits VWAP snapshots and anchor rates. Anchor rates are immutable once committed.
contract CentuariRateOracle is
    Initializable,
    OwnableUpgradeable,
    CentuariRateOracleStorage,
    ICentuariRateOracle
{
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function initialize(address owner_, address authorizedSigner_) external initializer {
        if (owner_ == address(0) || authorizedSigner_ == address(0)) revert ZeroAddress();
        __Ownable_init(owner_);
        _authorizedSigner = authorizedSigner_;
    }

    // ============ Rate Commits ============

    /// @inheritdoc ICentuariRateOracle
    function commitAnchorRate(
        address asset,
        uint256 currentMaturity,
        uint256 nextMaturity,
        uint256 anchorRateBPS,
        uint8 computationMethod,
        uint256 computedAt,
        bytes calldata engineSig
    ) external override {
        // Verify signature
        bytes32 digest = keccak256(abi.encode(
            "commitAnchorRate", asset, currentMaturity, nextMaturity,
            anchorRateBPS, computationMethod, computedAt
        ));
        _verifySig(digest, engineSig);

        // Immutability check
        if (_anchorRates[asset][currentMaturity][nextMaturity].committed) {
            revert AnchorRateAlreadyCommitted(asset, currentMaturity, nextMaturity);
        }

        _anchorRates[asset][currentMaturity][nextMaturity] = AnchorRate({
            anchorRateBPS: anchorRateBPS,
            computationMethod: computationMethod,
            computedAt: computedAt,
            committed: true
        });

        emit AnchorRateCommitted(asset, currentMaturity, nextMaturity, anchorRateBPS, computationMethod);
    }

    /// @inheritdoc ICentuariRateOracle
    /// @dev HIGH-4 FIX: Added monotonic nonce per (asset, maturity) for replay prevention,
    ///      and ±500 bps bounds check vs previous snapshot to prevent rate manipulation.
    function commitRateSnapshot(
        address asset,
        uint256 maturity,
        uint256 vwapBPS,
        bytes calldata engineSig
    ) external override {
        // Include nonce in digest for replay prevention
        uint256 currentNonce = _snapshotNonce[asset][maturity];
        bytes32 digest = keccak256(abi.encode("commitRateSnapshot", asset, maturity, vwapBPS, currentNonce));
        _verifySig(digest, engineSig);

        // HIGH-4 FIX: Rate bounds check vs previous snapshot
        RateSnapshot storage prev = _rateSnapshots[asset][maturity];
        if (prev.committedAt > 0 && prev.vwapBPS > 0) {
            uint256 rateChange = vwapBPS > prev.vwapBPS
                ? vwapBPS - prev.vwapBPS
                : prev.vwapBPS - vwapBPS;
            require(rateChange <= MAX_RATE_CHANGE_BPS, "CentuariRateOracle: rate change too large");
        }

        _rateSnapshots[asset][maturity] = RateSnapshot({
            vwapBPS: vwapBPS,
            committedAt: block.timestamp
        });
        _snapshotNonce[asset][maturity] = currentNonce + 1;

        emit RateSnapshotCommitted(asset, maturity, vwapBPS, block.timestamp);
    }

    // ============ Read Functions ============

    /// @inheritdoc ICentuariRateOracle
    function getRate(address asset, uint256 maturity) external view override returns (uint256, uint256) {
        RateSnapshot storage s = _rateSnapshots[asset][maturity];
        if (s.committedAt == 0) revert RateNotFound(asset, maturity);
        return (s.vwapBPS, s.committedAt);
    }

    /// @inheritdoc ICentuariRateOracle
    function getLatestVWAP(address asset, uint256 maturity) external view override returns (uint256) {
        return _rateSnapshots[asset][maturity].vwapBPS;
    }

    /// @inheritdoc ICentuariRateOracle
    function getActiveMaturities(address asset) external view override returns (uint256[] memory) {
        return _activeMaturities[asset];
    }

    /// @inheritdoc ICentuariRateOracle
    function getCBTFairValue(address cbtAddress) external view override returns (uint256) {
        // Read CBT underlying and maturity
        (bool ok1, bytes memory data1) = cbtAddress.staticcall(abi.encodeWithSignature("maturity()"));
        (bool ok2, bytes memory data2) = cbtAddress.staticcall(abi.encodeWithSignature("underlying()"));
        if (!ok1 || !ok2) return 1e18; // default $1.00 if can't read

        uint256 maturity = abi.decode(data1, (uint256));
        address underlying = abi.decode(data2, (address));

        if (block.timestamp >= maturity) return 1e18; // At/past maturity = $1.00

        RateSnapshot storage s = _rateSnapshots[underlying][maturity];
        if (s.committedAt == 0) return 1e18; // No rate data, assume par

        // Linear fair value: $1.00 / (1 + rate * timeRemaining)
        uint256 timeRemaining = maturity - block.timestamp;
        uint256 denominator = SECONDS_PER_YEAR * BPS_DENOMINATOR + s.vwapBPS * timeRemaining;
        return (1e18 * SECONDS_PER_YEAR * BPS_DENOMINATOR) / denominator;
    }

    /// @inheritdoc ICentuariRateOracle
    function isRateFresh(address asset, uint256 maturity, uint256 maxStaleSeconds) external view override returns (bool) {
        RateSnapshot storage s = _rateSnapshots[asset][maturity];
        if (s.committedAt == 0) return false;
        return block.timestamp - s.committedAt <= maxStaleSeconds;
    }

    /// @inheritdoc ICentuariRateOracle
    function getRatesForAsset(address asset) external view override returns (
        uint256[] memory maturities, uint256[] memory ratesBPS, uint256[] memory committedAts
    ) {
        maturities = _activeMaturities[asset];
        ratesBPS = new uint256[](maturities.length);
        committedAts = new uint256[](maturities.length);
        for (uint256 i = 0; i < maturities.length; i++) {
            RateSnapshot storage s = _rateSnapshots[asset][maturities[i]];
            ratesBPS[i] = s.vwapBPS;
            committedAts[i] = s.committedAt;
        }
    }

    /// @inheritdoc ICentuariRateOracle
    function getAnchorRate(address asset, uint256 currentMaturity, uint256 nextMaturity) external view override returns (uint256) {
        return _anchorRates[asset][currentMaturity][nextMaturity].anchorRateBPS;
    }

    /// @notice Get the current snapshot nonce for a (asset, maturity) pair
    function getSnapshotNonce(address asset, uint256 maturity) external view returns (uint256) {
        return _snapshotNonce[asset][maturity];
    }

    // ============ Admin ============

    /// @notice Propose active maturities for an asset with 48h timelock.
    function proposeActiveMaturities(address asset, uint256[] calldata maturities) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        _pendingActiveMaturities[asset] = maturities;
        _pendingActiveMaturitiesTimelockEnd[asset] = block.timestamp + ADMIN_TIMELOCK;
    }

    function applyActiveMaturities(address asset) external onlyOwner {
        require(_pendingActiveMaturitiesTimelockEnd[asset] != 0, "CentuariRateOracle: no pending maturities");
        require(block.timestamp >= _pendingActiveMaturitiesTimelockEnd[asset], "CentuariRateOracle: timelock active");
        _activeMaturities[asset] = _pendingActiveMaturities[asset];
        delete _pendingActiveMaturities[asset];
        delete _pendingActiveMaturitiesTimelockEnd[asset];
    }

    function cancelActiveMaturitiesProposal(address asset) external onlyOwner {
        delete _pendingActiveMaturities[asset];
        delete _pendingActiveMaturitiesTimelockEnd[asset];
    }

    /// @notice H-04 FIX: Propose a new oracle signer — starts 48h timelock
    function proposeOracleSigner(address newSigner) external onlyOwner {
        if (newSigner == address(0)) revert ZeroAddress();
        _pendingOracleSigner = newSigner;
        _oracleSignerTimelockEnd = block.timestamp + 48 hours;
    }

    /// @notice Apply pending oracle signer after timelock expires
    function applyOracleSigner() external onlyOwner {
        require(_pendingOracleSigner != address(0), "CentuariRateOracle: no pending signer");
        require(block.timestamp >= _oracleSignerTimelockEnd, "CentuariRateOracle: timelock not expired");
        _authorizedSigner = _pendingOracleSigner;
        _pendingOracleSigner = address(0);
        _oracleSignerTimelockEnd = 0;
    }

    /// @notice Cancel pending signer proposal
    function cancelOracleSigner() external onlyOwner {
        _pendingOracleSigner = address(0);
        _oracleSignerTimelockEnd = 0;
    }

    /// @notice DEPRECATED — use proposeOracleSigner() + applyOracleSigner() instead
    function updateSigner(address) external view onlyOwner {
        revert("CentuariRateOracle: use proposeOracleSigner");
    }

    // ============ Internal ============

    function _verifySig(bytes32 digest, bytes calldata sig) internal view {
        bytes32 ethHash = digest.toEthSignedMessageHash();
        address recovered = ethHash.recover(sig);
        if (recovered != _authorizedSigner) revert InvalidSignature();
    }
}
