// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "../utils/ReentrancyGuardUpgradeable.sol";

import {ICollateralRegistry} from "../interfaces/ICollateralRegistry.sol";
import {IBalanceLedger} from "../interfaces/IBalanceLedger.sol";
import {CollateralRegistryStorage} from "./CollateralRegistryStorage.sol";

/// @title CollateralRegistry
/// @notice Manages RWA attestation processing from spoke chains via LayerZero
/// @dev Receives attestation messages, validates replay protection, creates collateral positions.
///      Security Invariant #10: rejects attestations where timestamp <= lastAttestationTs
///      per (user, asset, spokeChainId).
contract CollateralRegistry is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    CollateralRegistryStorage,
    ICollateralRegistry
{
    // ============ Constructor ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initializer ============

    function initialize(
        address owner_,
        address balanceLedger_
    ) external initializer {
        if (owner_ == address(0) || balanceLedger_ == address(0)) revert ZeroAddress();
        __Ownable_init(owner_);
        __ReentrancyGuard_init();
        _balanceLedger = balanceLedger_;
    }

    // ============ Modifiers ============

    modifier onlyLayerZeroReceiver() {
        if (msg.sender != _layerZeroReceiver) revert Unauthorized();
        _;
    }

    modifier onlyKeeper() {
        if (!_authorizedKeepers[msg.sender]) revert Unauthorized();
        _;
    }

    // ============ Attestation Processing ============

    /// @inheritdoc ICollateralRegistry
    function processAttestation(
        bytes32 attestationId,
        address user,
        address asset,
        uint256 amount,
        uint256 attestationTimestamp,
        uint256 sourceChainId
    ) external override onlyLayerZeroReceiver nonReentrant {
        if (user == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        // Replay prevention: attestation ID must not have been used before
        if (_usedAttestationIds[attestationId]) {
            revert AttestationAlreadyUsed(attestationId);
        }

        // Monotonic timestamp: must be strictly greater than last for this (user, asset, chainId)
        uint256 lastTs = _lastAttestationTs[user][asset][sourceChainId];
        if (attestationTimestamp <= lastTs) {
            revert AttestationTooOld(attestationTimestamp, lastTs);
        }

        // Mark as used
        _usedAttestationIds[attestationId] = true;
        _lastAttestationTs[user][asset][sourceChainId] = attestationTimestamp;

        // Create or update collateral position in BalanceLedger
        IBalanceLedger(_balanceLedger).addCollateral(user, asset, amount, sourceChainId);

        emit AttestationProcessed(attestationId, user, asset, amount, sourceChainId);
    }

    /// @inheritdoc ICollateralRegistry
    function refreshCollateralValues(address[] calldata users) external override onlyKeeper {
        // In production, this would read Chainlink prices for each user's collateral
        // and update usdValueCached in BalanceLedger. For now, it's a keeper-triggered
        // batch operation that external systems can call.
        // The actual price read and cache update happens per-position.
        for (uint256 i = 0; i < users.length; i++) {
            // Emit event per user for off-chain tracking
            // In full implementation: iterate collateral positions, read price, update cache
        }
    }

    /// @inheritdoc ICollateralRegistry
    function updateCollateralValue(
        address user,
        address asset,
        uint256 newUsdValue
    ) external override onlyKeeper {
        if (user == address(0)) revert ZeroAddress();
        // In production, this updates the usdValueCached field in BalanceLedger's CollateralPosition
        // For now, emit event for off-chain tracking
        emit CollateralValueUpdated(user, asset, newUsdValue);
    }

    // ============ View Functions ============

    /// @inheritdoc ICollateralRegistry
    function isAttestationUsed(bytes32 attestationId) external view override returns (bool) {
        return _usedAttestationIds[attestationId];
    }

    /// @inheritdoc ICollateralRegistry
    function getLastAttestationTs(
        address user,
        address asset,
        uint256 sourceChainId
    ) external view override returns (uint256) {
        return _lastAttestationTs[user][asset][sourceChainId];
    }

    // ============ Administrative ============

    function setLayerZeroReceiver(address receiver) external onlyOwner {
        if (receiver == address(0)) revert ZeroAddress();
        _layerZeroReceiver = receiver;
    }

    function setKeeper(address keeper, bool authorized) external onlyOwner {
        _authorizedKeepers[keeper] = authorized;
    }

    function setBalanceLedger(address balanceLedger_) external onlyOwner {
        _balanceLedger = balanceLedger_;
    }
}
