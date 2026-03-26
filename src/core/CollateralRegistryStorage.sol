// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title CollateralRegistryStorage
/// @notice Storage layout for CollateralRegistry upgradeable contract
abstract contract CollateralRegistryStorage {
    /// @notice Processed attestation IDs — prevents replay (Security Invariant #10)
    mapping(bytes32 => bool) internal _usedAttestationIds;

    /// @notice Monotonic timestamp check per (user, asset, chainId) — prevents out-of-order processing
    /// @dev user => asset => chainId => lastTimestamp
    mapping(address => mapping(address => mapping(uint256 => uint256))) internal _lastAttestationTs;

    /// @notice BalanceLedger contract address
    address internal _balanceLedger;

    /// @notice Authorized LayerZero receiver address (for attestation messages)
    address internal _layerZeroReceiver;

    /// @notice Authorized keeper addresses (for value refreshes)
    mapping(address => bool) internal _authorizedKeepers;

    /// @notice RiskModule address (for collateral value updates)
    address internal _riskModule;

    /// @notice Price feed addresses per asset (Chainlink-compatible)
    mapping(address => address) internal _priceFeeds;

    /// @notice pCBT vault addresses (asset => true if it's a pCBT vault)
    mapping(address => bool) internal _isPCBTVault;

    /// @notice M-03 FIX: AssetBehaviorRegistry for maxStaleness lookup during refresh
    address internal _assetBehaviorRegistry;

    /// @notice CRIT-2 FIX: Timelock vars for setPriceFeed — moved from CollateralRegistry.sol
    mapping(address => address) internal _pendingPriceFeed;
    mapping(address => uint256) internal _pendingPriceFeedTimestamp;

    /// @notice Price feed timelock duration
    uint256 internal constant PRICE_FEED_TIMELOCK = 48 hours;

    /// @notice Admin timelock duration
    uint256 internal constant ADMIN_TIMELOCK = 48 hours;

    /// @notice Pending admin address changes keyed by bytes32 identifier (48h timelock)
    mapping(bytes32 => address) internal _pendingAdminAddress;

    /// @notice Timelock end timestamps for pending admin address changes
    mapping(bytes32 => uint256) internal _pendingAdminTimelockEnd;

    /// @notice Pending authorized-caller bool keyed by caller address (48h timelock)
    mapping(address => bool) internal _pendingAdminBool;

    // ============ Gap ============

    uint256[34] private __gap;
}
