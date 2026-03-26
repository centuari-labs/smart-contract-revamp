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

    /// @notice Propose a LayerZero receiver change with 48h timelock.
    function proposeLayerZeroReceiver(address receiver) external onlyOwner {
        if (receiver == address(0)) revert ZeroAddress();
        bytes32 key = keccak256("layerZeroReceiver");
        _pendingAdminAddress[key] = receiver;
        _pendingAdminTimelockEnd[key] = block.timestamp + ADMIN_TIMELOCK;
    }

    /// @notice Apply a pending LayerZero receiver change after the 48h timelock has elapsed.
    function applyLayerZeroReceiver() external onlyOwner {
        bytes32 key = keccak256("layerZeroReceiver");
        require(_pendingAdminAddress[key] != address(0), "CollateralRegistry: no pending receiver");
        require(block.timestamp >= _pendingAdminTimelockEnd[key], "CollateralRegistry: timelock active");
        _layerZeroReceiver = _pendingAdminAddress[key];
        delete _pendingAdminAddress[key];
        delete _pendingAdminTimelockEnd[key];
    }

    /// @notice Cancel a pending LayerZero receiver change.
    function cancelLayerZeroReceiverProposal() external onlyOwner {
        bytes32 key = keccak256("layerZeroReceiver");
        delete _pendingAdminAddress[key];
        delete _pendingAdminTimelockEnd[key];
    }

    /// @notice Propose a keeper authorization change with 48h timelock.
    function proposeKeeperChange(address keeper, bool authorized) external onlyOwner {
        if (keeper == address(0)) revert ZeroAddress();
        bytes32 key = bytes32(uint256(uint160(keeper)));
        _pendingAdminAddress[key] = keeper;
        _pendingAdminBool[keeper] = authorized;
        _pendingAdminTimelockEnd[key] = block.timestamp + ADMIN_TIMELOCK;
    }

    /// @notice Apply a pending keeper authorization change after the 48h timelock has elapsed.
    function applyKeeperChange(address keeper) external onlyOwner {
        bytes32 key = bytes32(uint256(uint160(keeper)));
        require(_pendingAdminAddress[key] != address(0), "CollateralRegistry: no pending keeper change");
        require(block.timestamp >= _pendingAdminTimelockEnd[key], "CollateralRegistry: timelock active");
        _authorizedKeepers[keeper] = _pendingAdminBool[keeper];
        delete _pendingAdminAddress[key];
        delete _pendingAdminTimelockEnd[key];
        delete _pendingAdminBool[keeper];
    }

    /// @notice Cancel a pending keeper authorization change.
    function cancelKeeperChange(address keeper) external onlyOwner {
        bytes32 key = bytes32(uint256(uint160(keeper)));
        delete _pendingAdminAddress[key];
        delete _pendingAdminTimelockEnd[key];
        delete _pendingAdminBool[keeper];
    }

    /// @notice Propose a BalanceLedger address change with 48h timelock.
    function proposeBalanceLedger(address balanceLedger_) external onlyOwner {
        if (balanceLedger_ == address(0)) revert ZeroAddress();
        bytes32 key = keccak256("balanceLedger");
        _pendingAdminAddress[key] = balanceLedger_;
        _pendingAdminTimelockEnd[key] = block.timestamp + ADMIN_TIMELOCK;
    }

    /// @notice Apply a pending BalanceLedger address change after the 48h timelock has elapsed.
    function applyBalanceLedger() external onlyOwner {
        bytes32 key = keccak256("balanceLedger");
        require(_pendingAdminAddress[key] != address(0), "CollateralRegistry: no pending balance ledger");
        require(block.timestamp >= _pendingAdminTimelockEnd[key], "CollateralRegistry: timelock active");
        _balanceLedger = _pendingAdminAddress[key];
        delete _pendingAdminAddress[key];
        delete _pendingAdminTimelockEnd[key];
    }

    /// @notice Cancel a pending BalanceLedger address change.
    function cancelBalanceLedgerProposal() external onlyOwner {
        bytes32 key = keccak256("balanceLedger");
        delete _pendingAdminAddress[key];
        delete _pendingAdminTimelockEnd[key];
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

    /// @notice Propose a pCBT vault status change with 48h timelock.
    function proposePCBTVault(address vault, bool isPCBT) external onlyOwner {
        if (vault == address(0)) revert ZeroAddress();
        bytes32 key = bytes32(uint256(uint160(vault)));
        _pendingAdminAddress[key] = vault;
        _pendingAdminBool[vault] = isPCBT;
        _pendingAdminTimelockEnd[key] = block.timestamp + ADMIN_TIMELOCK;
    }

    /// @notice Apply a pending pCBT vault status change after the 48h timelock has elapsed.
    function applyPCBTVault(address vault) external onlyOwner {
        bytes32 key = bytes32(uint256(uint160(vault)));
        require(_pendingAdminAddress[key] != address(0), "CollateralRegistry: no pending pCBT vault change");
        require(block.timestamp >= _pendingAdminTimelockEnd[key], "CollateralRegistry: timelock active");
        _isPCBTVault[vault] = _pendingAdminBool[vault];
        delete _pendingAdminAddress[key];
        delete _pendingAdminTimelockEnd[key];
        delete _pendingAdminBool[vault];
    }

    /// @notice Cancel a pending pCBT vault status change.
    function cancelPCBTVaultProposal(address vault) external onlyOwner {
        bytes32 key = bytes32(uint256(uint160(vault)));
        delete _pendingAdminAddress[key];
        delete _pendingAdminTimelockEnd[key];
        delete _pendingAdminBool[vault];
    }

    /// @notice Propose an AssetBehaviorRegistry address change with 48h timelock.
    function proposeAssetBehaviorRegistry(address registry_) external onlyOwner {
        if (registry_ == address(0)) revert ZeroAddress();
        bytes32 key = keccak256("assetBehaviorRegistry");
        _pendingAdminAddress[key] = registry_;
        _pendingAdminTimelockEnd[key] = block.timestamp + ADMIN_TIMELOCK;
    }

    /// @notice Apply a pending AssetBehaviorRegistry address change after the 48h timelock has elapsed.
    function applyAssetBehaviorRegistry() external onlyOwner {
        bytes32 key = keccak256("assetBehaviorRegistry");
        require(_pendingAdminAddress[key] != address(0), "CollateralRegistry: no pending registry");
        require(block.timestamp >= _pendingAdminTimelockEnd[key], "CollateralRegistry: timelock active");
        _assetBehaviorRegistry = _pendingAdminAddress[key];
        delete _pendingAdminAddress[key];
        delete _pendingAdminTimelockEnd[key];
    }

    /// @notice Cancel a pending AssetBehaviorRegistry address change.
    function cancelAssetBehaviorRegistryProposal() external onlyOwner {
        bytes32 key = keccak256("assetBehaviorRegistry");
        delete _pendingAdminAddress[key];
        delete _pendingAdminTimelockEnd[key];
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
