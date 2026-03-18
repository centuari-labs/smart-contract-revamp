// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title CentuariRateOracleStorage
/// @notice Storage layout for CentuariRateOracle
abstract contract CentuariRateOracleStorage {
    struct RateSnapshot {
        uint256 vwapBPS;
        uint256 committedAt;
    }

    struct AnchorRate {
        uint256 anchorRateBPS;
        uint8 computationMethod; // 0=VWAP, 1=TERM_PREMIUM, 2=PROTOCOL_DEFAULT
        uint256 computedAt;
        bool committed; // immutable once true
    }

    /// @notice Rate snapshots per (asset, maturity)
    mapping(address => mapping(uint256 => RateSnapshot)) internal _rateSnapshots;

    /// @notice Anchor rates per (asset, currentMaturity, nextMaturity)
    mapping(address => mapping(uint256 => mapping(uint256 => AnchorRate))) internal _anchorRates;

    /// @notice Active maturities per asset (max 3)
    mapping(address => uint256[]) internal _activeMaturities;

    /// @notice Authorized engine signer for commits
    address internal _authorizedSigner;

    /// @notice BPS denominator
    uint256 internal constant BPS_DENOMINATOR = 10000;

    /// @notice Seconds per year
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    // ============ Gap ============

    uint256[44] private __gap;
}
