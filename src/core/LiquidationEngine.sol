// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "../utils/ReentrancyGuardUpgradeable.sol";

import {ILiquidationEngine} from "../interfaces/ILiquidationEngine.sol";
import {IRiskModule} from "../interfaces/IRiskModule.sol";
import {IBalanceLedger} from "../interfaces/IBalanceLedger.sol";
import {IAssetBehaviorRegistry} from "../interfaces/IAssetBehaviorRegistry.sol";
import {LiquidationEngineStorage} from "./LiquidationEngineStorage.sol";
import {ILayerZeroEndpointV2} from "../interfaces/ILayerZeroEndpointV2.sol";

/// @title LiquidationEngine
/// @notice Executes liquidations for undercollateralized positions
/// @dev Supports hub-native and cross-chain RWA collateral. Enforces grace periods on-chain.
///      Security Invariant #11: cannot use stale price feed.
contract LiquidationEngine is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    LiquidationEngineStorage,
    ILiquidationEngine
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
        address riskModule_,
        address assetBehaviorRegistry_
    ) external initializer {
        if (owner_ == address(0) || balanceLedger_ == address(0) ||
            riskModule_ == address(0) || assetBehaviorRegistry_ == address(0)) {
            revert Unauthorized();
        }
        __Ownable_init(owner_);
        __ReentrancyGuard_init();

        _balanceLedger = balanceLedger_;
        _riskModule = riskModule_;
        _assetBehaviorRegistry = assetBehaviorRegistry_;
    }

    // ============ Modifiers ============

    modifier onlyAuthorized() {
        if (!_authorizedCallers[msg.sender]) revert Unauthorized();
        _;
    }

    // ============ Constants ============

    /// @inheritdoc ILiquidationEngine
    function MAX_GRACE_PERIOD_HOURS() external pure override returns (uint256) {
        return _MAX_GRACE_PERIOD_HOURS;
    }

    // ============ Liquidation ============

    /// @inheritdoc ILiquidationEngine
    function liquidate(
        address borrower,
        address debtAsset,
        uint256 debtToCover,
        address collateralAsset
    ) external override nonReentrant {
        IRiskModule riskModule = IRiskModule(_riskModule);
        IBalanceLedger ledger = IBalanceLedger(_balanceLedger);
        IAssetBehaviorRegistry registry = IAssetBehaviorRegistry(_assetBehaviorRegistry);

        // 1. Verify position is liquidatable (HF < 1.0)
        uint256 hf = riskModule.getHealthFactor(borrower);
        if (hf >= HF_PRECISION) revert PositionHealthy(hf);

        // 2. Check grace period not active
        // (Positions in grace period cannot be liquidated until deadline passes)
        // HIGH-2 FIX: Include collateralAsset in positionId to prevent grace period bypass.
        // Without this, attacker uses different debtAsset to get a different key → no grace period.
        bytes32 positionId = keccak256(abi.encode(borrower, debtAsset, collateralAsset));
        GracePeriodState storage grace = _gracePeriods[positionId];
        if (grace.deadlineTimestamp > 0 && block.timestamp < grace.deadlineTimestamp) {
            revert GracePeriodNotExpired(grace.deadlineTimestamp, block.timestamp);
        }

        // 3. Verify debt coverage <= 50%
        uint256 totalDebt = riskModule.getTotalDebtUSD(borrower);
        uint256 maxCoverage = (totalDebt * MAX_DEBT_COVERAGE_BPS) / BPS_DENOMINATOR;
        if (debtToCover > maxCoverage) revert ExceedsMaxDebtCoverage(debtToCover, maxCoverage);

        // 4. Verify oracle freshness (Security Invariant #11)
        if (!riskModule.isPriceFresh(collateralAsset)) revert PriceFeedStale();

        // 5. Verify collateral is active and enabled
        IBalanceLedger.CollateralPosition memory collPos = ledger.getCollateralByAsset(borrower, collateralAsset);
        if (collPos.state != IBalanceLedger.CollateralState.ACTIVE) revert CollateralNotActive();
        if (!ledger.getIsUsedAsCollateral(borrower, collateralAsset)) revert CollateralNotEnabled();

        // 6. Verify liquidator is approved for this asset (RWA whitelist)
        if (!registry.isLiquidatorApproved(collateralAsset, msg.sender)) {
            revert LiquidatorNotApproved(msg.sender, collateralAsset);
        }

        // 7. Compute collateral to seize (including bonus)
        // H-08 FIX: Use fresh oracle price instead of stale usdValueCached.
        // The cached value could be hours old — liquidation must use current market price.
        IAssetBehaviorRegistry.AssetBehavior memory behavior = registry.getBehavior(collateralAsset);
        uint256 bonusBPS = behavior.liquidationBonusBPS;
        (uint256 pricePerUnit18,) = riskModule.getAssetPriceUSD(collateralAsset);
        uint256 freshCollateralUsdValue = (pricePerUnit18 * collPos.amount) / 1e18;
        uint256 collateralToSeize = _computeSeizure(debtToCover, freshCollateralUsdValue, collPos.amount, bonusBPS);

        if (collateralToSeize > collPos.amount) revert InsufficientCollateral();

        // Update cache with fresh value (benefits subsequent HF checks)
        ledger.updateCollateralUsdValue(borrower, collateralAsset, freshCollateralUsdValue);

        // 8. Execute liquidation (hub-native path)
        // CRIT-01 FIX: The permissionless liquidate() must enforce full token flows.
        // Without this, a liquidator receives collateral without paying anything.
        // Pattern: Aave V3 LiquidationLogic — liquidator pays debt, receives collateral.

        // 8a. Debit debt repayment FROM liquidator's BalanceLedger available balance.
        // The liquidator must have deposited the debt asset beforehand.
        ledger.debit(msg.sender, debtAsset, debtToCover);

        // 8b. Reduce borrower's collateral
        ledger.reduceCollateral(borrower, collateralAsset, collateralToSeize);

        // 8c. Credit seized collateral (including bonus) TO liquidator
        ledger.addCollateral(msg.sender, collateralAsset, collateralToSeize, block.chainid);

        // 8d. Reduce borrower's debt in RiskModule
        // CRIT-1 FIX: Normalize debt to 18 decimals before passing to RiskModule.
        // RiskModule tracks debt in 18-decimal USD. debtToCover is in asset-native decimals
        // (e.g., 6 for USDC). Without normalization, each liquidation reduces debt by 10^-12
        // of the correct amount, allowing loop-draining of all collateral.
        uint256 debtNormalized18 = _normalizeToUSD18(debtAsset, debtToCover);
        riskModule.reduceUserDebt(borrower, debtNormalized18);
        riskModule.reduceDebtAgainstAsset(collateralAsset, debtNormalized18);

        // Clear grace period if it was set
        if (grace.deadlineTimestamp > 0) {
            delete _gracePeriods[positionId];
        }

        emit LiquidationExecuted(
            borrower, msg.sender, collateralAsset,
            collateralToSeize, debtToCover, bonusBPS
        );
    }

    /// @inheritdoc ILiquidationEngine
    /// @dev B1 FIX: Real cross-chain liquidation retry via LayerZero V2.
    ///      Re-sends the stored liquidation message if the original delivery failed.
    function retryLiquidation(bytes32 requestId) external override onlyAuthorized {
        PendingCrossChainLiq storage pending = _pendingCrossChainLiqs[requestId];
        require(pending.borrower != address(0), "LiquidationEngine: no pending liquidation");
        require(!pending.completed, "LiquidationEngine: already completed");

        _sendCrossChainLiquidation(
            requestId, pending.borrower, pending.collateralAsset,
            pending.collateralToSeize, pending.liquidator, pending.spokeChainEid
        );
    }

    /// @notice B1 FIX: Internal cross-chain liquidation via LayerZero V2.
    /// @dev Sends a message to SpokeVaultRWA on the spoke chain to release collateral.
    ///      The spoke's lzReceive() verifies sender + chain before releasing.
    function _sendCrossChainLiquidation(
        bytes32 requestId,
        address borrower,
        address collateralAsset,
        uint256 collateralToSeize,
        address liquidator,
        uint32 spokeChainEid
    ) internal {
        require(_layerZeroEndpoint != address(0), "LiquidationEngine: LZ endpoint not set");

        bytes memory payload = abi.encode(borrower, collateralAsset, collateralToSeize, liquidator);

        // Build LZ V2 messaging params
        ILayerZeroEndpointV2.MessagingParams memory params = ILayerZeroEndpointV2.MessagingParams({
            dstEid: spokeChainEid,
            receiver: bytes32(uint256(uint160(_spokeVaultRWA[spokeChainEid]))),
            message: payload,
            options: bytes(""), // Default options — gas paid by protocol
            payInLzToken: false
        });

        ILayerZeroEndpointV2(_layerZeroEndpoint).send{value: msg.value}(params, msg.sender);

        emit CrossChainLiquidationInitiated(requestId, borrower, collateralAsset, collateralToSeize);
    }

    // ============ Grace Period ============

    /// @inheritdoc ILiquidationEngine
    /// @dev 1C FIX: penaltyRateBPS is now a parameter, computed off-chain as 2x VWAP
    ///      from CentuariRateOracle.getLatestVWAP(). This eliminates free optionality
    ///      during grace period — borrowers pay for the delay.
    function setGracePeriod(
        bytes32 positionId,
        uint256 gracePeriodHours,
        uint8 reason,
        uint256 penaltyRateBPS
    ) external override onlyAuthorized {
        if (gracePeriodHours > _MAX_GRACE_PERIOD_HOURS) {
            revert ExceedsMaxGracePeriod(gracePeriodHours, _MAX_GRACE_PERIOD_HOURS);
        }

        _gracePeriods[positionId] = GracePeriodState({
            startTimestamp: block.timestamp,
            deadlineTimestamp: block.timestamp + (gracePeriodHours * 1 hours),
            reason: reason,
            penaltyRateBPS: penaltyRateBPS,
            accruedPenalty: 0
        });

        emit GracePeriodSet(address(0), positionId, block.timestamp + (gracePeriodHours * 1 hours), reason);
    }

    /// @inheritdoc ILiquidationEngine
    function flagForLiquidation(bytes32 positionId) external override onlyAuthorized {
        GracePeriodState storage grace = _gracePeriods[positionId];
        require(grace.deadlineTimestamp > 0 && block.timestamp >= grace.deadlineTimestamp, "Grace period not expired");

        _liquidatable[positionId] = true;
        emit PositionFlaggedLiquidatable(positionId);
    }

    /// @inheritdoc ILiquidationEngine
    function getGracePeriod(bytes32 positionId) external view override returns (GracePeriodState memory) {
        return _gracePeriods[positionId];
    }

    /// @inheritdoc ILiquidationEngine
    function isInGracePeriod(bytes32 positionId) external view override returns (bool) {
        GracePeriodState storage grace = _gracePeriods[positionId];
        return grace.deadlineTimestamp > 0 && block.timestamp < grace.deadlineTimestamp;
    }

    /// @inheritdoc ILiquidationEngine
    function isLiquidatable(bytes32 positionId) external view override returns (bool) {
        return _liquidatable[positionId];
    }

    // ============ Administrative ============

    /// @notice Propose an address-type admin change with 48h timelock
    /// @dev Keys: keccak256("rateOracle") and keccak256("layerZeroEndpoint")
    /// @param key  A bytes32 identifier for the parameter being changed
    /// @param newAddr The new address to set after the timelock
    function proposeAdminChange(bytes32 key, address newAddr) external onlyOwner {
        if (newAddr == address(0)) revert Unauthorized();
        _pendingAdminAddress[key] = newAddr;
        _pendingAdminTimelockEnd[key] = block.timestamp + 48 hours;
    }

    /// @notice Apply a pending address-type admin change after the 48h timelock has elapsed
    /// @param key The bytes32 identifier used in proposeAdminChange
    function applyAdminChange(bytes32 key) external onlyOwner {
        address newAddr = _pendingAdminAddress[key];
        require(newAddr != address(0), "LiquidationEngine: no pending change");
        require(block.timestamp >= _pendingAdminTimelockEnd[key], "LiquidationEngine: timelock active");

        if (key == keccak256("rateOracle")) {
            _rateOracle = newAddr;
        } else if (key == keccak256("layerZeroEndpoint")) {
            _layerZeroEndpoint = newAddr;
        } else {
            revert("LiquidationEngine: unknown key");
        }

        delete _pendingAdminAddress[key];
        delete _pendingAdminTimelockEnd[key];
    }

    /// @notice Cancel a pending address-type admin change
    /// @param key The bytes32 identifier used in proposeAdminChange
    function cancelAdminChange(bytes32 key) external onlyOwner {
        delete _pendingAdminAddress[key];
        delete _pendingAdminTimelockEnd[key];
    }

    /// @notice Propose an authorized-caller change with 48h timelock
    /// @param caller The address whose authorization is being changed
    /// @param authorized Whether to grant or revoke caller access
    function proposeAuthorizedCallerChange(address caller, bool authorized) external onlyOwner {
        if (caller == address(0)) revert Unauthorized();
        _pendingAdminAddress[bytes32(uint256(uint160(caller)))] = caller;
        _pendingAdminBool[caller] = authorized;
        _pendingAdminTimelockEnd[bytes32(uint256(uint160(caller)))] = block.timestamp + 48 hours;
    }

    /// @notice Apply a pending authorized-caller change after the 48h timelock has elapsed
    /// @param caller The address whose authorization is being applied
    function applyAuthorizedCallerChange(address caller) external onlyOwner {
        bytes32 key = bytes32(uint256(uint160(caller)));
        require(_pendingAdminAddress[key] != address(0), "LiquidationEngine: no pending change");
        require(block.timestamp >= _pendingAdminTimelockEnd[key], "LiquidationEngine: timelock active");

        _authorizedCallers[caller] = _pendingAdminBool[caller];

        delete _pendingAdminAddress[key];
        delete _pendingAdminTimelockEnd[key];
        delete _pendingAdminBool[caller];
    }

    /// @notice Cancel a pending authorized-caller change
    /// @param caller The address whose pending change is being cancelled
    function cancelAuthorizedCallerChange(address caller) external onlyOwner {
        bytes32 key = bytes32(uint256(uint160(caller)));
        delete _pendingAdminAddress[key];
        delete _pendingAdminTimelockEnd[key];
        delete _pendingAdminBool[caller];
    }

    /// @notice B1 FIX: Set SpokeVaultRWA address for a spoke chain
    /// @dev Used for cross-chain liquidation message routing
    function setSpokeVaultRWA(uint32 spokeEid, address vault) external onlyOwner {
        _spokeVaultRWA[spokeEid] = vault;
    }

    // ============ Internal ============

    /// @notice Compute collateral amount to seize including liquidation bonus
    function _computeSeizure(
        uint256 debtToCover,
        uint256 collateralUsdValue,
        uint256 collateralAmount,
        uint256 bonusBPS
    ) internal pure returns (uint256) {
        if (collateralUsdValue == 0) return 0;

        // debtToCover is in USD (18 decimals)
        // collateralUsdValue is total position USD value
        // collateralAmount is total position token amount
        // Include bonus: seize = (debtToCover / collateralPricePerUnit) * (1 + bonus)
        uint256 debtWithBonus = debtToCover * (BPS_DENOMINATOR + bonusBPS) / BPS_DENOMINATOR;
        return (debtWithBonus * collateralAmount) / collateralUsdValue;
    }

    /// @notice CRIT-1 FIX: Normalize asset-native amount to 18-decimal USD.
    /// @dev USDC (6 dec) → multiply by 10^12. ETH (18 dec) → multiply by 10^0.
    function _normalizeToUSD18(address asset, uint256 amount) internal view returns (uint256) {
        (bool success, bytes memory data) = asset.staticcall(abi.encodeWithSignature("decimals()"));
        uint8 decimals = success && data.length >= 32 ? abi.decode(data, (uint8)) : 18;
        if (decimals >= 18) return amount;
        return amount * (10 ** (18 - decimals));
    }
}
