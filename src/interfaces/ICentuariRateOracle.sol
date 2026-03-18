// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ICentuariRateOracle
/// @notice On-chain rate feed for external protocol integration
/// @dev Engine commits VWAP rate snapshots and anchor rates. External protocols read rates on-chain.
interface ICentuariRateOracle {
    // ============ Rate Commits (Engine-signed) ============

    /// @notice Commit an anchor rate before maturity (T-1 hour). Immutable once committed.
    /// @param asset The lending asset
    /// @param currentMaturity The expiring maturity
    /// @param nextMaturity The destination maturity
    /// @param anchorRateBPS The anchor rate in basis points
    /// @param computationMethod 0=VWAP, 1=TERM_PREMIUM, 2=PROTOCOL_DEFAULT
    /// @param computedAt Timestamp when anchor was computed
    /// @param engineSig Engine ECDSA signature
    function commitAnchorRate(
        address asset,
        uint256 currentMaturity,
        uint256 nextMaturity,
        uint256 anchorRateBPS,
        uint8 computationMethod,
        uint256 computedAt,
        bytes calldata engineSig
    ) external;

    /// @notice Commit a rate snapshot (periodic, every 100 batches)
    /// @param asset The asset
    /// @param maturity The maturity
    /// @param vwapBPS Volume-weighted average rate in BPS
    /// @param engineSig Engine ECDSA signature
    function commitRateSnapshot(
        address asset,
        uint256 maturity,
        uint256 vwapBPS,
        bytes calldata engineSig
    ) external;

    // ============ Read Functions (for external protocols) ============

    /// @notice Get current VWAP rate for an asset/maturity pair
    /// @param asset The asset
    /// @param maturity The maturity
    /// @return rateBPS Rate in basis points
    /// @return committedAt Timestamp of last commit
    function getRate(address asset, uint256 maturity) external view returns (uint256 rateBPS, uint256 committedAt);

    /// @notice Get latest VWAP rate for an asset at a specific maturity
    function getLatestVWAP(address asset, uint256 maturity) external view returns (uint256 vwapBPS);

    /// @notice Get all active maturities for an asset (max 3)
    function getActiveMaturities(address asset) external view returns (uint256[] memory maturities);

    /// @notice Get CBT fair value using linear model
    /// @dev fairValue = faceValue / (1 + committedRate * timeRemaining)
    /// @param cbtAddress The CBT contract address
    /// @return fairValueUSD18 Fair value in USD with 18 decimals
    function getCBTFairValue(address cbtAddress) external view returns (uint256 fairValueUSD18);

    /// @notice Check if rate is fresh (updated within maxStaleSeconds)
    function isRateFresh(address asset, uint256 maturity, uint256 maxStaleSeconds) external view returns (bool);

    /// @notice Batch get rates for all active maturities of an asset
    function getRatesForAsset(address asset) external view returns (
        uint256[] memory maturities,
        uint256[] memory ratesBPS,
        uint256[] memory committedAts
    );

    /// @notice Get anchor rate for a maturity transition
    function getAnchorRate(
        address asset,
        uint256 currentMaturity,
        uint256 nextMaturity
    ) external view returns (uint256 anchorRateBPS);

    // ============ Events ============

    event RateSnapshotCommitted(address indexed asset, uint256 indexed maturity, uint256 vwapBPS, uint256 committedAt);
    event AnchorRateCommitted(address indexed asset, uint256 indexed currentMaturity, uint256 nextMaturity, uint256 anchorRateBPS, uint8 computationMethod);

    // ============ Errors ============

    error Unauthorized();
    error InvalidSignature();
    error AnchorRateAlreadyCommitted(address asset, uint256 currentMaturity, uint256 nextMaturity);
    error RateNotFound(address asset, uint256 maturity);
    error ZeroAddress();
}
