// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "../utils/ReentrancyGuardUpgradeable.sol";

import {IAssetBehaviorRegistry} from "../interfaces/IAssetBehaviorRegistry.sol";
import {IMarketScheduleRegistry} from "../interfaces/IMarketScheduleRegistry.sol";
import {AssetBehaviorRegistryStorage} from "./AssetBehaviorRegistryStorage.sol";

/// @title AssetBehaviorRegistry
/// @notice Root configuration for every whitelisted asset in the protocol
/// @dev All core contracts read AssetBehavior from this registry.
///      Adding/updating assets requires 48h timelock (Security Invariant #7).
///      Deactivation and pause are conservative actions (no timelock).
contract AssetBehaviorRegistry is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    AssetBehaviorRegistryStorage,
    IAssetBehaviorRegistry
{
    // ============ Constructor ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initializer ============

    function initialize(address owner_) external initializer {
        if (owner_ == address(0)) revert ZeroAddress();
        __Ownable_init(owner_);
        __ReentrancyGuard_init();
    }

    // ============ Modifiers ============

    modifier whenNotPaused() {
        require(!_paused, "AssetBehaviorRegistry: paused");
        _;
    }

    // ============ Asset Management ============

    /// @notice H-03 FIX: Propose a new asset — starts 48h timelock (Invariant #7)
    /// @dev Previously addAsset() was instant. Now split into propose/execute with timelock.
    function proposeAsset(
        address asset,
        AssetBehavior calldata behavior
    ) external onlyOwner whenNotPaused nonReentrant {
        if (asset == address(0)) revert ZeroAddress();
        if (_behaviors[asset].active) revert AssetAlreadyExists();
        if (behavior.liquidationBonusBPS > MAX_LIQUIDATION_BONUS_BPS) revert MaxLiquidationBonusExceeded();
        _validateBehavior(behavior);

        _pendingAssets[asset] = behavior;
        _pendingAssetTimestamp[asset] = block.timestamp + TIMELOCK_DURATION;

        emit AssetProposed(asset, behavior.assetClass);
    }

    /// @notice Execute a pending asset proposal after timelock expires
    function executeAddAsset(address asset) external onlyOwner whenNotPaused nonReentrant {
        if (_pendingAssetTimestamp[asset] == 0) revert AssetNotFound();
        if (block.timestamp < _pendingAssetTimestamp[asset]) revert TimelockNotExpired();
        if (_behaviors[asset].active) revert AssetAlreadyExists();

        _behaviors[asset] = _pendingAssets[asset];
        _behaviors[asset].active = true;
        _assetAddedAt[asset] = block.timestamp;
        _lastUpdateAt[asset] = block.timestamp; // P1-a FIX: enforce timelock from creation

        delete _pendingAssets[asset];
        delete _pendingAssetTimestamp[asset];

        emit AssetAdded(asset, _behaviors[asset].assetClass);
    }

    /// @notice Cancel a pending asset proposal
    function cancelProposeAsset(address asset) external onlyOwner {
        delete _pendingAssets[asset];
        delete _pendingAssetTimestamp[asset];
    }

    /// @inheritdoc IAssetBehaviorRegistry
    /// @dev DEPRECATED — use proposeAsset() + executeAddAsset() instead. Kept for interface compat.
    function addAsset(
        address asset,
        AssetBehavior calldata behavior
    ) external override onlyOwner whenNotPaused nonReentrant {
        revert TimelockNotExpired(); // Force use of propose/execute pattern
    }

    /// @inheritdoc IAssetBehaviorRegistry
    function updateAsset(
        address asset,
        AssetBehavior calldata behavior
    ) external override onlyOwner whenNotPaused nonReentrant {
        if (!_behaviors[asset].active) revert AssetNotFound();
        if (behavior.liquidationBonusBPS > MAX_LIQUIDATION_BONUS_BPS) revert MaxLiquidationBonusExceeded();

        // Timelock enforcement: must wait 48h after last update (Security Invariant #7)
        if (_lastUpdateAt[asset] != 0 && block.timestamp < _lastUpdateAt[asset] + TIMELOCK_DURATION) {
            revert TimelockNotExpired();
        }

        _validateBehavior(behavior);

        // If LTV changed, create a pending change (discrete governance model)
        if (behavior.maxLTV != _behaviors[asset].maxLTV ||
            behavior.liquidationThreshold != _behaviors[asset].liquidationThreshold) {
            _pendingLTVChanges[asset] = LTVChange({
                newMaxLTV: behavior.maxLTV,
                newLiqThreshold: behavior.liquidationThreshold,
                effectiveTimestamp: block.timestamp,
                appliedToExisting: false
            });
            emit LTVChangeProposed(asset, behavior.maxLTV, behavior.liquidationThreshold);

            // New positions use new LTV immediately, existing positions keep old
            // Store old LTV in pending for reference
        }

        _behaviors[asset] = behavior;
        _behaviors[asset].active = true;
        _lastUpdateAt[asset] = block.timestamp;

        emit AssetUpdated(asset);
    }

    /// @inheritdoc IAssetBehaviorRegistry
    function deactivateAsset(address asset) external override onlyOwner {
        if (!_behaviors[asset].active) revert AssetNotFound();
        _behaviors[asset].active = false;
        emit AssetDeactivated(asset);
    }

    /// @inheritdoc IAssetBehaviorRegistry
    function pauseAsset(address asset) external override onlyOwner {
        if (!_behaviors[asset].active) revert AssetNotFound();
        _assetPaused[asset] = true;
        emit AssetPaused(asset);
    }

    /// @inheritdoc IAssetBehaviorRegistry
    function unpauseAsset(address asset) external override onlyOwner {
        // Unpausing requires timelock (re-enabling is riskier)
        if (_lastUpdateAt[asset] != 0 && block.timestamp < _lastUpdateAt[asset] + TIMELOCK_DURATION) {
            revert TimelockNotExpired();
        }
        _assetPaused[asset] = false;
        _lastUpdateAt[asset] = block.timestamp;
        emit AssetUnpaused(asset);
    }

    /// @inheritdoc IAssetBehaviorRegistry
    function applyLTVToExisting(address asset) external override onlyOwner {
        LTVChange storage change = _pendingLTVChanges[asset];
        if (change.effectiveTimestamp == 0) revert AssetNotFound();
        if (block.timestamp < change.effectiveTimestamp + LTV_OBSERVATION_PERIOD) {
            revert ObservationPeriodNotComplete();
        }

        _behaviors[asset].maxLTV = change.newMaxLTV;
        _behaviors[asset].liquidationThreshold = change.newLiqThreshold;
        change.appliedToExisting = true;

        emit LTVAppliedToExisting(asset, change.newMaxLTV);
    }

    // ============ Liquidator Whitelist ============

    /// @inheritdoc IAssetBehaviorRegistry
    function addLiquidator(address asset, address liquidator) external override onlyOwner {
        if (asset == address(0) || liquidator == address(0)) revert ZeroAddress();
        if (!_liquidatorWhitelist[asset][liquidator]) {
            _liquidatorWhitelist[asset][liquidator] = true;
            _liquidatorList[asset].push(liquidator);
            emit LiquidatorAdded(asset, liquidator);
        }
    }

    /// @inheritdoc IAssetBehaviorRegistry
    function removeLiquidator(address asset, address liquidator) external override onlyOwner {
        _liquidatorWhitelist[asset][liquidator] = false;
        emit LiquidatorRemoved(asset, liquidator);
    }

    /// @inheritdoc IAssetBehaviorRegistry
    function isLiquidatorApproved(
        address asset,
        address liquidator
    ) external view override returns (bool) {
        // If no whitelist set (empty list), anyone can liquidate
        if (_liquidatorList[asset].length == 0) return true;
        return _liquidatorWhitelist[asset][liquidator];
    }

    // ============ Administrative ============

    /// @notice Propose a market schedule registry change with 48h timelock.
    function proposeMarketScheduleRegistry(address registry) external onlyOwner {
        if (registry == address(0)) revert ZeroAddress();
        bytes32 key = keccak256("marketScheduleRegistry");
        _pendingAdminAddress[key] = registry;
        _pendingAdminTimelockEnd[key] = block.timestamp + ADMIN_TIMELOCK;
    }

    function applyMarketScheduleRegistry() external onlyOwner {
        bytes32 key = keccak256("marketScheduleRegistry");
        require(_pendingAdminAddress[key] != address(0), "AssetBehaviorRegistry: no pending registry");
        require(block.timestamp >= _pendingAdminTimelockEnd[key], "AssetBehaviorRegistry: timelock active");
        _marketScheduleRegistry = _pendingAdminAddress[key];
        delete _pendingAdminAddress[key];
        delete _pendingAdminTimelockEnd[key];
    }

    function cancelMarketScheduleRegistryProposal() external onlyOwner {
        bytes32 key = keccak256("marketScheduleRegistry");
        delete _pendingAdminAddress[key];
        delete _pendingAdminTimelockEnd[key];
    }

    function pause() external onlyOwner {
        _paused = true;
    }

    function unpause() external onlyOwner {
        _paused = false;
    }

    // ============ View Functions ============

    /// @inheritdoc IAssetBehaviorRegistry
    function getBehavior(address asset) external view override returns (AssetBehavior memory) {
        return _behaviors[asset];
    }

    /// @inheritdoc IAssetBehaviorRegistry
    function isAssetPaused(address asset) external view override returns (bool) {
        return _assetPaused[asset];
    }

    /// @inheritdoc IAssetBehaviorRegistry
    function getEffectiveLiqThreshold(address asset) external view override returns (uint256) {
        AssetBehavior storage b = _behaviors[asset];
        uint256 threshold = b.liquidationThreshold;

        if (b.hasMarketHours && _marketScheduleRegistry != address(0)) {
            bool isOpen = IMarketScheduleRegistry(_marketScheduleRegistry).isOpen(b.marketSchedule);
            if (!isOpen) {
                threshold = threshold > b.afterHoursLTVBuffer
                    ? threshold - b.afterHoursLTVBuffer
                    : 0;
            }
        }

        return threshold;
    }

    /// @inheritdoc IAssetBehaviorRegistry
    function getEffectiveMaxLTV(address asset) external view override returns (uint256) {
        AssetBehavior storage b = _behaviors[asset];
        uint256 ltv = b.maxLTV;

        if (b.hasMarketHours && _marketScheduleRegistry != address(0)) {
            bool isOpen = IMarketScheduleRegistry(_marketScheduleRegistry).isOpen(b.marketSchedule);
            if (!isOpen) {
                ltv = ltv > b.afterHoursLTVBuffer ? ltv - b.afterHoursLTVBuffer : 0;
            }
        }

        return ltv;
    }

    /// @inheritdoc IAssetBehaviorRegistry
    function getPendingLTVChange(address asset) external view override returns (LTVChange memory) {
        return _pendingLTVChanges[asset];
    }

    // ============ Internal ============

    function _validateBehavior(AssetBehavior calldata b) internal pure {
        if (b.maxLTV > 10000) revert InvalidLTV();
        if (b.liquidationThreshold > 10000) revert InvalidLiquidationThreshold();
        if (b.liquidationThreshold < b.maxLTV) revert InvalidLiquidationThreshold();
    }
}
