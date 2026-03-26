// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {IRiskModule} from "../interfaces/IRiskModule.sol";
import {IBalanceLedger} from "../interfaces/IBalanceLedger.sol";
import {IAssetBehaviorRegistry} from "../interfaces/IAssetBehaviorRegistry.sol";
import {RiskModuleStorage} from "./RiskModuleStorage.sol";

/// @title RiskModule
/// @notice Pure computation contract for health factor, LTV enforcement, and liquidation eligibility
/// @dev HF = sum(collateral_i_USD * liqThreshold_i) / totalDebtUSD (Aave V3 pattern)
///      All view functions read from BalanceLedger, AssetBehaviorRegistry, and price feeds.
contract RiskModule is
    Initializable,
    OwnableUpgradeable,
    RiskModuleStorage,
    IRiskModule
{
    // ============ Constructor ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initializer ============

    function initialize(
        address owner_,
        address balanceLedger_,
        address assetBehaviorRegistry_
    ) external initializer {
        if (owner_ == address(0) || balanceLedger_ == address(0) || assetBehaviorRegistry_ == address(0)) {
            revert Unauthorized();
        }
        __Ownable_init(owner_);
        _balanceLedger = balanceLedger_;
        _assetBehaviorRegistry = assetBehaviorRegistry_;
    }

    // ============ Modifiers ============

    modifier onlyAuthorized() {
        if (!_authorizedCallers[msg.sender]) revert Unauthorized();
        _;
    }

    // ============ Health Factor ============

    /// @inheritdoc IRiskModule
    function getHealthFactor(address user) external view override returns (uint256 hf18) {
        uint256 weightedCollateral = _getWeightedCollateralUSD(user);
        uint256 totalDebt = _userDebtUSD[user];

        if (totalDebt == 0) return type(uint256).max;
        return (weightedCollateral * HF_PRECISION) / totalDebt;
    }

    /// @inheritdoc IRiskModule
    function getWeightedCollateralUSD(address user) external view override returns (uint256) {
        return _getWeightedCollateralUSD(user);
    }

    /// @inheritdoc IRiskModule
    function getWeightedCollateralExcluding(
        address user,
        address excludeAsset
    ) external view override returns (uint256 weightedUSD) {
        IBalanceLedger.CollateralPosition[] memory positions = IBalanceLedger(_balanceLedger).getCollateral(user);

        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].asset == excludeAsset) continue;
            if (positions[i].state != IBalanceLedger.CollateralState.ACTIVE) continue;
            if (!IBalanceLedger(_balanceLedger).getIsUsedAsCollateral(user, positions[i].asset)) continue;

            uint256 usdValue = positions[i].usdValueCached;
            uint256 liqThreshold = IAssetBehaviorRegistry(_assetBehaviorRegistry)
                .getEffectiveLiqThreshold(positions[i].asset);

            weightedUSD += (usdValue * liqThreshold) / BPS_DENOMINATOR;
        }
    }

    /// @inheritdoc IRiskModule
    function getTotalDebtUSD(address user) external view override returns (uint256) {
        return _userDebtUSD[user];
    }

    // ============ LTV and Thresholds ============

    /// @inheritdoc IRiskModule
    function getEffectiveLiqThreshold(address asset) external view override returns (uint256) {
        return IAssetBehaviorRegistry(_assetBehaviorRegistry).getEffectiveLiqThreshold(asset);
    }

    /// @inheritdoc IRiskModule
    function getEffectiveMaxLTV(address asset) external view override returns (uint256) {
        return IAssetBehaviorRegistry(_assetBehaviorRegistry).getEffectiveMaxLTV(asset);
    }

    // ============ Borrow Validation ============

    /// @inheritdoc IRiskModule
    function validateBorrow(
        address borrower,
        address borrowAsset,
        uint256 borrowAmount,
        address[] calldata collateralAssets
    ) external view override returns (bool valid, string memory reason) {
        IAssetBehaviorRegistry registry = IAssetBehaviorRegistry(_assetBehaviorRegistry);
        IBalanceLedger ledger = IBalanceLedger(_balanceLedger);

        // 1. Check all collateral assets have isUsedAsCollateral = true
        for (uint256 i = 0; i < collateralAssets.length; i++) {
            if (!ledger.getIsUsedAsCollateral(borrower, collateralAssets[i])) {
                return (false, "COLLATERAL_NOT_ENABLED");
            }
        }

        // 2. Check debt ceiling per collateral asset
        for (uint256 i = 0; i < collateralAssets.length; i++) {
            IAssetBehaviorRegistry.AssetBehavior memory behavior = registry.getBehavior(collateralAssets[i]);
            if (behavior.debtCeiling > 0) {
                uint256 currentDebt = _totalDebtAgainstAsset[collateralAssets[i]];
                // Simple USD conversion (assumes borrowAsset is USD-pegged stablecoin)
                if (currentDebt + borrowAmount > behavior.debtCeiling) {
                    return (false, "DEBT_CEILING_EXCEEDED");
                }
            }
        }

        // 3. Check weighted HF would remain >= 1.0 after new borrow
        uint256 weightedColl = _getWeightedCollateralUSD(borrower);
        uint256 existingDebt = _userDebtUSD[borrower];
        uint256 newTotalDebt = existingDebt + borrowAmount;

        if (newTotalDebt > 0 && (weightedColl * HF_PRECISION) / newTotalDebt < HF_PRECISION) {
            return (false, "INSUFFICIENT_COLLATERAL");
        }

        // 4. Check minimum borrow amount
        IAssetBehaviorRegistry.AssetBehavior memory borrowBehavior = registry.getBehavior(borrowAsset);
        if (borrowAmount < borrowBehavior.minBorrowAmount) {
            return (false, "BELOW_MIN_BORROW_AMOUNT");
        }

        return (true, "");
    }

    // ============ Debt Tracking ============

    /// @inheritdoc IRiskModule
    function getTotalDebtAgainstAsset(address collateralAsset) external view override returns (uint256) {
        return _totalDebtAgainstAsset[collateralAsset];
    }

    /// @inheritdoc IRiskModule
    function recordDebtAgainstAsset(address collateralAsset, uint256 debtUSD) external override onlyAuthorized {
        _totalDebtAgainstAsset[collateralAsset] += debtUSD;
        emit DebtRecorded(collateralAsset, debtUSD);
    }

    /// @inheritdoc IRiskModule
    function reduceDebtAgainstAsset(address collateralAsset, uint256 debtUSD) external override onlyAuthorized {
        _totalDebtAgainstAsset[collateralAsset] -= debtUSD;
        emit DebtReduced(collateralAsset, debtUSD);
    }

    /// @notice Record user debt (called by CentuariEndpoint during settlement)
    function recordUserDebt(address user, uint256 debtUSD) external onlyAuthorized {
        _userDebtUSD[user] += debtUSD;
    }

    /// @notice Reduce user debt (called on repayment/liquidation)
    function reduceUserDebt(address user, uint256 debtUSD) external onlyAuthorized {
        _userDebtUSD[user] -= debtUSD;
    }

    // ============ Price Queries ============

    /// @inheritdoc IRiskModule
    function getAssetPriceUSD(address asset) external view override returns (uint256 priceUSD, uint256 updatedAt) {
        return _getAssetPriceUSDInternal(asset);
    }

    /// @notice HIGH-01 FIX: Internal oracle read shared by getAssetPriceUSD AND _getWeightedCollateralUSD.
    /// @dev Before this fix, getAssetPriceUSD was external-only. _getWeightedCollateralUSD used stale
    ///      usdValueCached for HF computation, meaning withdraw() and setAsCollateral() relied on
    ///      keeper-refreshed prices that could be hours old. With this fix, HF always uses live oracle
    ///      prices when a Chainlink feed is configured, falling back to cache only for attestation-only
    ///      assets (RWAs without on-chain price feeds).
    ///      Reference: Loopscale ($5.8M, 2025) — stale oracle during HF check enabled undercollateralized borrows.
    ///      Reference: Venus ($200M at risk, 2021) — stale XVS price allowed massive overborrowing.
    function _getAssetPriceUSDInternal(address asset) internal view returns (uint256 priceUSD, uint256 updatedAt) {
        IAssetBehaviorRegistry.AssetBehavior memory behavior = IAssetBehaviorRegistry(_assetBehaviorRegistry)
            .getBehavior(asset);

        if (behavior.priceFeed == address(0)) {
            return (0, 0);
        }

        // Call Chainlink AggregatorV3Interface
        (,int256 answer,,uint256 updatedAt_,) = _latestRoundData(behavior.priceFeed);

        // C-02 FIX: Reject non-positive prices.
        require(answer > 0, "RiskModule: non-positive price");

        // 2F FIX: Enforce per-asset price sanity bounds (0 = no bound enforced).
        if (behavior.minPrice > 0) require(uint256(answer) >= behavior.minPrice, "RiskModule: price below min");
        if (behavior.maxPrice > 0) require(uint256(answer) <= behavior.maxPrice, "RiskModule: price above max");

        // Convert to 18 decimals
        uint8 feedDecimals = _feedDecimals(behavior.priceFeed);
        priceUSD = uint256(answer) * (10 ** (18 - feedDecimals));
        updatedAt = updatedAt_;
    }

    /// @notice A1 FIX: Dual-oracle verification for maturity processing.
    /// @dev Reads both primary and secondary feeds. Returns true if both are fresh and within 2% divergence.
    ///      If secondary feed is address(0), falls back to single-oracle with halved maxStaleness.
    ///      Reference: Loopscale $5.8M exploit — single-oracle manipulation at maturity.
    /// @param asset The asset to verify
    /// @return valid True if price is verified
    /// @return price The primary oracle price in 18 decimals
    function verifyDualOracle(address asset) external view returns (bool valid, uint256 price) {
        IAssetBehaviorRegistry.AssetBehavior memory behavior = IAssetBehaviorRegistry(_assetBehaviorRegistry)
            .getBehavior(asset);

        if (behavior.priceFeed == address(0)) return (false, 0);

        // Read primary
        (,int256 primaryAnswer,,uint256 primaryUpdatedAt,) = _latestRoundData(behavior.priceFeed);
        if (primaryAnswer <= 0) return (false, 0);

        uint8 primaryDecimals = _feedDecimals(behavior.priceFeed);
        uint256 primaryPrice18 = uint256(primaryAnswer) * (10 ** (18 - primaryDecimals));

        // No secondary feed → single-oracle with halved maxStaleness
        if (behavior.secondaryPriceFeed == address(0)) {
            uint256 effectiveStaleness = behavior.maxStaleness / 2;
            if (effectiveStaleness > 0 && block.timestamp - primaryUpdatedAt > effectiveStaleness) {
                return (false, primaryPrice18);
            }
            return (true, primaryPrice18);
        }

        // Read secondary
        (bool secSuccess, bytes memory secData) = behavior.secondaryPriceFeed.staticcall(
            abi.encodeWithSignature("latestRoundData()")
        );
        if (!secSuccess || secData.length == 0) {
            // Secondary unavailable → fallback to single with halved staleness
            uint256 effectiveStaleness = behavior.maxStaleness / 2;
            if (effectiveStaleness > 0 && block.timestamp - primaryUpdatedAt > effectiveStaleness) {
                return (false, primaryPrice18);
            }
            return (true, primaryPrice18);
        }

        (, int256 secAnswer,, uint256 secUpdatedAt,) = abi.decode(secData, (uint80, int256, uint256, uint256, uint80));
        if (secAnswer <= 0) return (true, primaryPrice18); // Bad secondary → trust primary

        uint8 secDecimals = _feedDecimals(behavior.secondaryPriceFeed);
        uint256 secPrice18 = uint256(secAnswer) * (10 ** (18 - secDecimals));

        // Check staleness on both feeds
        uint256 secStaleness = behavior.secondaryMaxStaleness > 0
            ? behavior.secondaryMaxStaleness : behavior.maxStaleness;
        if (behavior.maxStaleness > 0 && block.timestamp - primaryUpdatedAt > behavior.maxStaleness) {
            return (false, primaryPrice18);
        }
        if (secStaleness > 0 && block.timestamp - secUpdatedAt > secStaleness) {
            return (false, primaryPrice18);
        }

        // Check divergence: |primary - secondary| / primary <= 2% (200 BPS)
        uint256 diff = primaryPrice18 > secPrice18
            ? primaryPrice18 - secPrice18
            : secPrice18 - primaryPrice18;
        uint256 divergenceBPS = (diff * 10000) / primaryPrice18;

        if (divergenceBPS > 200) {
            return (false, primaryPrice18); // >2% divergence — defer processing
        }

        return (true, primaryPrice18);
    }

    /// @inheritdoc IRiskModule
    function isPriceFresh(address asset) external view override returns (bool) {
        IAssetBehaviorRegistry.AssetBehavior memory behavior = IAssetBehaviorRegistry(_assetBehaviorRegistry)
            .getBehavior(asset);

        if (behavior.priceFeed == address(0)) return false;

        (,,,uint256 updatedAt,) = _latestRoundData(behavior.priceFeed);
        return block.timestamp - updatedAt <= behavior.maxStaleness;
    }

    // ============ Administrative ============

    /// @notice HIGH-03 FIX: setAuthorizedCaller with 48h timelock.
    /// @dev CRIT-2 FIX: Timelock vars moved to RiskModuleStorage.sol to prevent storage corruption on upgrade.
    ///      An authorized caller can record/reduce arbitrary debt amounts.
    ///      Instant granting enables "position assassination" — inflate a user's debt to trigger liquidation.
    function proposeAuthorizedCaller(address caller, bool authorized) external onlyOwner {
        require(caller != address(0), "RiskModule: zero address");
        _pendingAuthorizedCaller = caller;
        _pendingCallerAuthorized = authorized;
        _pendingCallerTimelockEnd = block.timestamp + ADMIN_TIMELOCK;
    }

    function applyAuthorizedCaller() external onlyOwner {
        require(_pendingAuthorizedCaller != address(0), "RiskModule: no pending");
        require(block.timestamp >= _pendingCallerTimelockEnd, "RiskModule: timelock active");
        _authorizedCallers[_pendingAuthorizedCaller] = _pendingCallerAuthorized;
        delete _pendingAuthorizedCaller;
        delete _pendingCallerAuthorized;
        delete _pendingCallerTimelockEnd;
    }

    function cancelAuthorizedCallerProposal() external onlyOwner {
        delete _pendingAuthorizedCaller;
        delete _pendingCallerAuthorized;
        delete _pendingCallerTimelockEnd;
    }

    /// @notice Propose a BalanceLedger address change with 48h timelock
    /// @param balanceLedger_ The new BalanceLedger address
    function proposeBalanceLedger(address balanceLedger_) external onlyOwner {
        if (balanceLedger_ == address(0)) revert Unauthorized();
        bytes32 key = keccak256("balanceLedger");
        _pendingAdminAddress[key] = balanceLedger_;
        _pendingAdminTimelockEnd[key] = block.timestamp + ADMIN_TIMELOCK;
    }

    /// @notice Apply a pending BalanceLedger change after the 48h timelock has elapsed
    function applyBalanceLedger() external onlyOwner {
        bytes32 key = keccak256("balanceLedger");
        require(_pendingAdminAddress[key] != address(0), "RiskModule: no pending balanceLedger");
        require(block.timestamp >= _pendingAdminTimelockEnd[key], "RiskModule: timelock active");
        _balanceLedger = _pendingAdminAddress[key];
        delete _pendingAdminAddress[key];
        delete _pendingAdminTimelockEnd[key];
    }

    /// @notice Cancel a pending BalanceLedger change
    function cancelBalanceLedger() external onlyOwner {
        bytes32 key = keccak256("balanceLedger");
        delete _pendingAdminAddress[key];
        delete _pendingAdminTimelockEnd[key];
    }

    /// @notice Propose an AssetBehaviorRegistry address change with 48h timelock
    /// @param registry_ The new AssetBehaviorRegistry address
    function proposeAssetBehaviorRegistry(address registry_) external onlyOwner {
        if (registry_ == address(0)) revert Unauthorized();
        bytes32 key = keccak256("assetBehaviorRegistry");
        _pendingAdminAddress[key] = registry_;
        _pendingAdminTimelockEnd[key] = block.timestamp + ADMIN_TIMELOCK;
    }

    /// @notice Apply a pending AssetBehaviorRegistry change after the 48h timelock has elapsed
    function applyAssetBehaviorRegistry() external onlyOwner {
        bytes32 key = keccak256("assetBehaviorRegistry");
        require(_pendingAdminAddress[key] != address(0), "RiskModule: no pending assetBehaviorRegistry");
        require(block.timestamp >= _pendingAdminTimelockEnd[key], "RiskModule: timelock active");
        _assetBehaviorRegistry = _pendingAdminAddress[key];
        delete _pendingAdminAddress[key];
        delete _pendingAdminTimelockEnd[key];
    }

    /// @notice Cancel a pending AssetBehaviorRegistry change
    function cancelAssetBehaviorRegistry() external onlyOwner {
        bytes32 key = keccak256("assetBehaviorRegistry");
        delete _pendingAdminAddress[key];
        delete _pendingAdminTimelockEnd[key];
    }

    /// @notice PRE-AUDIT FIX: Set the L2 sequencer uptime feed address
    /// @dev On Arbitrum: 0xFdB631F5EE196F0ed6FAa767959853A9F217697D
    ///      Set to address(0) to disable the check (for testing or non-L2 deployment).
    function setSequencerUptimeFeed(address feed) external onlyOwner {
        _sequencerUptimeFeed = feed;
    }

    // ============ Internal ============

    /// @notice HIGH-01 FIX: Uses LIVE oracle prices for HF computation, not stale usdValueCached.
    /// @dev Before this fix, HF used keeper-refreshed cached values that could be hours old.
    ///      Now reads Chainlink directly for each collateral asset. Falls back to usdValueCached
    ///      only when no price feed is configured (attestation-only RWA assets).
    ///      Gas impact: ~2400 gas per oracle read per collateral asset. Acceptable for security-critical
    ///      operations (withdraw, setAsCollateral, validateBorrow).
    function _getWeightedCollateralUSD(address user) internal view returns (uint256 weightedUSD) {
        IBalanceLedger.CollateralPosition[] memory positions = IBalanceLedger(_balanceLedger).getCollateral(user);

        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].state != IBalanceLedger.CollateralState.ACTIVE) continue;
            if (!IBalanceLedger(_balanceLedger).getIsUsedAsCollateral(user, positions[i].asset)) continue;

            uint256 usdValue;

            // 2J FIX: Capture updatedAt from oracle to detect staleness.
            // When oracle data is stale or no feed is configured, apply a 20% haircut
            // to the cached USD value as a conservative fallback.
            (uint256 livePrice, uint256 oracleUpdatedAt) = _getAssetPriceUSDInternal(positions[i].asset);
            IAssetBehaviorRegistry.AssetBehavior memory behavior = IAssetBehaviorRegistry(_assetBehaviorRegistry)
                .getBehavior(positions[i].asset);

            bool priceIsStale = oracleUpdatedAt > 0
                && behavior.maxStaleness > 0
                && block.timestamp - oracleUpdatedAt > behavior.maxStaleness;

            if (livePrice > 0 && positions[i].amount > 0 && !priceIsStale) {
                // Fresh live price: compute full position value.
                // livePrice is per-unit in 18 decimals; normalize by token decimals.
                uint8 tokenDecimals = _getTokenDecimals(positions[i].asset);
                usdValue = (livePrice * positions[i].amount) / (10 ** tokenDecimals);
            } else {
                // Stale oracle or no feed configured (attestation-only RWA).
                // Apply 20% haircut to cached value as conservative estimate.
                usdValue = positions[i].usdValueCached * 80 / 100;
            }

            uint256 liqThreshold = IAssetBehaviorRegistry(_assetBehaviorRegistry)
                .getEffectiveLiqThreshold(positions[i].asset);

            weightedUSD += (usdValue * liqThreshold) / BPS_DENOMINATOR;
        }
    }

    /// @notice Get token decimals via staticcall with 18-decimal fallback
    function _getTokenDecimals(address token) internal view returns (uint8) {
        (bool success, bytes memory data) = token.staticcall(
            abi.encodeWithSignature("decimals()")
        );
        if (success && data.length >= 32) {
            return abi.decode(data, (uint8));
        }
        return 18; // Default fallback
    }

    function _latestRoundData(address feed) internal view returns (
        uint80, int256, uint256, uint256, uint80
    ) {
        // PRE-AUDIT FIX: Check Arbitrum L2 sequencer uptime before accepting oracle data.
        // After sequencer downtime, Chainlink feeds report fresh updatedAt but prices are stale.
        // Without this, liquidations could execute at stale prices after sequencer recovery.
        // Reference: Chainlink L2 Sequencer Uptime Feeds documentation.
        if (_sequencerUptimeFeed != address(0)) {
            (bool seqSuccess, bytes memory seqData) = _sequencerUptimeFeed.staticcall(
                abi.encodeWithSignature("latestRoundData()")
            );
            if (seqSuccess && seqData.length >= 160) {
                (, int256 seqAnswer,, uint256 seqStartedAt,) =
                    abi.decode(seqData, (uint80, int256, uint256, uint256, uint80));
                // seqAnswer == 0 means sequencer is UP, == 1 means DOWN
                require(seqAnswer == 0, "RiskModule: L2 sequencer is down");
                // Grace period: don't trust prices for SEQUENCER_GRACE_PERIOD after recovery
                require(
                    block.timestamp - seqStartedAt > SEQUENCER_GRACE_PERIOD,
                    "RiskModule: L2 sequencer grace period"
                );
            }
        }

        (bool success, bytes memory data) = feed.staticcall(
            abi.encodeWithSignature("latestRoundData()")
        );
        require(success, "RiskModule: price feed call failed");
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            abi.decode(data, (uint80, int256, uint256, uint256, uint80));
        // 2G FIX: Validate answeredInRound to detect stale Chainlink rounds during feed migrations
        require(answeredInRound >= roundId, "RiskModule: stale round");
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }

    function _feedDecimals(address feed) internal view returns (uint8) {
        (bool success, bytes memory data) = feed.staticcall(
            abi.encodeWithSignature("decimals()")
        );
        require(success, "RiskModule: decimals call failed");
        return abi.decode(data, (uint8));
    }
}
