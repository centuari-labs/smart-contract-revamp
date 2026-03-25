// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "../utils/ReentrancyGuardUpgradeable.sol";

import {ICollateralRegistry} from "../interfaces/ICollateralRegistry.sol";
import {IBalanceLedger} from "../interfaces/IBalanceLedger.sol";
import {IAssetBehaviorRegistry} from "../interfaces/IAssetBehaviorRegistry.sol";
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

                    // M-03 FIX: Reject stale price feeds.
                    // Without this check, a Chainlink feed that hasn't updated in hours
                    // silently produces incorrect collateral valuations.
                    if (_assetBehaviorRegistry != address(0)) {
                        uint256 maxStaleness = IAssetBehaviorRegistry(_assetBehaviorRegistry)
                            .getBehavior(pos.asset).maxStaleness;
                        if (maxStaleness > 0 && block.timestamp - updatedAt > maxStaleness) {
                            // P1-c FIX: Apply 20% haircut instead of silent skip (Venus Protocol pattern)
                            emit StalePriceDetected(pos.asset, updatedAt, maxStaleness);
                            uint256 currentCached = pos.usdValueCached;
                            if (currentCached > 0) {
                                ledger.updateCollateralUsdValue(user, pos.asset, (currentCached * 80) / 100);
                            }
                            continue;
                        }
                    }

                    uint8 feedDecimals = IAggregatorV3(feed).decimals();
                    // P0 FIX: Normalize to 18-decimal USD (matches RiskModule.getAssetPriceUSD)
                    uint256 priceNormalized = uint256(price) * (10 ** (18 - feedDecimals));
                    uint8 tokenDecimals = _getTokenDecimals(pos.asset);
                    usdValue = (pos.amount * priceNormalized) / (10 ** tokenDecimals);
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

        // P1-d FIX: Validate against oracle (max 50% deviation)
        address feed = _priceFeeds[asset];
        if (feed != address(0)) {
            (, int256 price,,,) = IAggregatorV3(feed).latestRoundData();
            if (price > 0) {
                IBalanceLedger.CollateralPosition memory pos =
                    IBalanceLedger(_balanceLedger).getCollateralByAsset(user, asset);
                uint8 feedDecimals = IAggregatorV3(feed).decimals();
                uint256 priceNorm = uint256(price) * (10 ** (18 - feedDecimals));
                uint8 tokenDecimals = _getTokenDecimals(asset);
                uint256 oracleValue = (pos.amount * priceNorm) / (10 ** tokenDecimals);
                require(
                    newUsdValue <= (oracleValue * 150) / 100 &&
                    (oracleValue == 0 || newUsdValue >= (oracleValue * 50) / 100),
                    "CollateralRegistry: value deviates > 50% from oracle"
                );
            }
        }

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

    /// @notice HIGH-03 FIX: setPriceFeed now requires 48h timelock.
    /// @dev CRIT-2 FIX: Timelock vars moved to CollateralRegistryStorage.sol to prevent storage corruption.
    ///      A compromised owner setting a malicious price feed could inflate collateral values
    ///      and drain the protocol. The 48h delay gives the community time to detect and respond.
    function proposePriceFeed(address asset, address feed) external onlyOwner {
        _pendingPriceFeed[asset] = feed;
        _pendingPriceFeedTimestamp[asset] = block.timestamp + PRICE_FEED_TIMELOCK;
        emit PriceFeedProposed(asset, feed, block.timestamp + PRICE_FEED_TIMELOCK);
    }

    function applyPriceFeed(address asset) external onlyOwner {
        require(_pendingPriceFeedTimestamp[asset] > 0, "CollateralRegistry: no pending feed");
        require(block.timestamp >= _pendingPriceFeedTimestamp[asset], "CollateralRegistry: timelock active");
        _priceFeeds[asset] = _pendingPriceFeed[asset];
        emit PriceFeedUpdated(asset, _pendingPriceFeed[asset]);
        delete _pendingPriceFeed[asset];
        delete _pendingPriceFeedTimestamp[asset];
    }

    function cancelPriceFeedProposal(address asset) external onlyOwner {
        delete _pendingPriceFeed[asset];
        delete _pendingPriceFeedTimestamp[asset];
    }

    event PriceFeedProposed(address indexed asset, address feed, uint256 unlockTime);
    event PriceFeedUpdated(address indexed asset, address feed);

    function setPCBTVault(address vault, bool isPCBT) external onlyOwner {
        _isPCBTVault[vault] = isPCBT;
    }

    function setAssetBehaviorRegistry(address registry_) external onlyOwner {
        _assetBehaviorRegistry = registry_;
    }

    // ============ Internal Helpers ============

    /// @notice Get token decimals via staticcall. Defaults to 18 if call fails.
    function _getTokenDecimals(address token) internal view returns (uint8) {
        (bool success, bytes memory data) = token.staticcall(
            abi.encodeWithSignature("decimals()")
        );
        if (!success || data.length == 0) return 18;
        return abi.decode(data, (uint8));
    }

    // ============ Events ============

    event CollateralValuesRefreshed(address indexed user);
    event StalePriceDetected(address indexed asset, uint256 updatedAt, uint256 maxStaleness);
}
