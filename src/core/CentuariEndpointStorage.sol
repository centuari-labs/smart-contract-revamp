// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ICentuariEndpoint} from "../interfaces/ICentuariEndpoint.sol";

/// @title CentuariEndpointStorage
/// @notice Storage layout for CentuariEndpoint upgradeable contract
abstract contract CentuariEndpointStorage {
    /// @notice Authorized engine signer address (HSM key)
    address internal _authorizedSigner;

    /// @notice Last processed settlement batch nonce (Security Invariant #2)
    uint256 internal _lastProcessedNonce;

    /// @notice Paused state — only multisig can toggle
    bool internal _paused;

    /// @notice Multisig address for pause/unpause
    address internal _multisig;

    /// @notice BalanceLedger contract
    address internal _balanceLedger;

    /// @notice RiskModule contract
    address internal _riskModule;

    /// @notice AssetBehaviorRegistry contract
    address internal _assetBehaviorRegistry;

    /// @notice Bond token factory for CBT operations
    address internal _bondTokenFactory;

    /// @notice Grace period states per position
    mapping(bytes32 => ICentuariEndpoint.GracePeriodStart) internal _gracePeriods;

    /// @notice CentuariRateOracle for anchor rate verification
    address internal _rateOracle;

    /// @notice Signer update timelock: timestamp when new signer can be applied
    uint256 internal _signerUpdateTimelockEnd;
    address internal _pendingSigner;

    /// @notice FeeController contract — all fee logic delegated here
    address internal _feeController;

    /// @notice Timestamp tolerance for batch validation (±60 seconds)
    uint256 internal constant TIMESTAMP_TOLERANCE = 60;

    /// @notice CBT mint amount tolerance (±1 wei)
    uint256 internal constant CBT_TOLERANCE = 1;

    /// @notice Rate precision (10000 = 100%)
    uint256 internal constant RATE_PRECISION = 10000;

    /// @notice Seconds per year for interest computation
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    /// @notice Protocol rate bounds (§3.13)
    uint256 internal constant MIN_RATE_BPS = 10;     // 0.10% floor
    uint256 internal constant MAX_RATE_BPS = 10000;  // 100.00% ceiling

    /// @notice Anchor rate tolerance for rollover/refinance (±50 bps)
    uint256 internal constant ANCHOR_RATE_TOLERANCE_BPS = 50;

    /// @notice Signer update timelock duration (48 hours)
    uint256 internal constant SIGNER_UPDATE_TIMELOCK = 48 hours;

    // ============ Gap ============

    uint256[34] private __gap;
}
