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

    // ============ Gap ============

    uint256[42] private __gap;
}
