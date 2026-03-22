// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "../utils/ReentrancyGuardUpgradeable.sol";

import {ICollateralRegistry} from "../interfaces/ICollateralRegistry.sol";
import {IBalanceLedger} from "../interfaces/IBalanceLedger.sol";
import {IPCBT} from "../interfaces/IPCBT.sol";
import {CollateralRegistryStorage} from "./CollateralRegistryStorage.sol";

/// @notice Minimal Chainlink AggregatorV3 interface for price reads
interface IAggregatorV3 {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function decimals() external view returns (uint8);
}

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
        IBalanceLedger ledger = IBalanceLedger(_balanceLedger);

        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            IBalanceLedger.CollateralPosition[] memory positions = ledger.getCollateral(user);

            for (uint256 j = 0; j < positions.length; j++) {
                IBalanceLedger.CollateralPosition memory pos = positions[j];
                if (pos.amount == 0) continue;

                uint256 usdValue;

                if (_isPCBTVault[pos.asset]) {
                    // pCBT vault: read collateral value directly from vault
                    uint256 valuePerShare = IPCBT(pos.asset).collateralValuePerPCBT();
                    usdValue = (pos.amount * valuePerShare) / 1e18;
                } else {
                    // Standard asset: read from Chainlink price feed
                    address feed = _priceFeeds[pos.asset];
                    if (feed == address(0)) continue;

                    (, int256 price,, uint256 updatedAt,) = IAggregatorV3(feed).latestRoundData();
                    if (price <= 0) continue;

                    uint8 feedDecimals = IAggregatorV3(feed).decimals();
                    usdValue = (pos.amount * uint256(price)) / (10 ** feedDecimals);
                }

                ledger.updateCollateralUsdValue(user, pos.asset, usdValue);
            }

            emit CollateralValuesRefreshed(user);
        }
    }

    /// @inheritdoc ICollateralRegistry
    function updateCollateralValue(
        address user,
        address asset,
        uint256 newUsdValue
    ) external override onlyKeeper {
        if (user == address(0)) revert ZeroAddress();

        // Write cached USD value to BalanceLedger — this is what RiskModule reads for HF computation
        IBalanceLedger(_balanceLedger).updateCollateralUsdValue(user, asset, newUsdValue);

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

    function setPriceFeed(address asset, address feed) external onlyOwner {
        _priceFeeds[asset] = feed;
    }

    function setPCBTVault(address vault, bool isPCBT) external onlyOwner {
        _isPCBTVault[vault] = isPCBT;
    }

    // ============ Events ============

    event CollateralValuesRefreshed(address indexed user);
}
