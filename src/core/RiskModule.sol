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
        IAssetBehaviorRegistry.AssetBehavior memory behavior = IAssetBehaviorRegistry(_assetBehaviorRegistry)
            .getBehavior(asset);

        if (behavior.priceFeed == address(0)) {
            return (0, 0);
        }

        // Call Chainlink AggregatorV3Interface
        (,int256 answer,,uint256 updatedAt_,) = _latestRoundData(behavior.priceFeed);

        // C-02 FIX: Reject non-positive prices. Negative int256 wraps to ~2^255
        // as uint256, corrupting all HF calculations and enabling unlimited borrowing.
        require(answer > 0, "RiskModule: non-positive price");

        // Convert to 18 decimals
        uint8 feedDecimals = _feedDecimals(behavior.priceFeed);
        priceUSD = uint256(answer) * (10 ** (18 - feedDecimals));
        updatedAt = updatedAt_;
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

    function setAuthorizedCaller(address caller, bool authorized) external onlyOwner {
        _authorizedCallers[caller] = authorized;
    }

    function setBalanceLedger(address balanceLedger_) external onlyOwner {
        _balanceLedger = balanceLedger_;
    }

    function setAssetBehaviorRegistry(address registry_) external onlyOwner {
        _assetBehaviorRegistry = registry_;
    }

    // ============ Internal ============

    function _getWeightedCollateralUSD(address user) internal view returns (uint256 weightedUSD) {
        IBalanceLedger.CollateralPosition[] memory positions = IBalanceLedger(_balanceLedger).getCollateral(user);

        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].state != IBalanceLedger.CollateralState.ACTIVE) continue;
            if (!IBalanceLedger(_balanceLedger).getIsUsedAsCollateral(user, positions[i].asset)) continue;

            uint256 usdValue = positions[i].usdValueCached;
            uint256 liqThreshold = IAssetBehaviorRegistry(_assetBehaviorRegistry)
                .getEffectiveLiqThreshold(positions[i].asset);

            weightedUSD += (usdValue * liqThreshold) / BPS_DENOMINATOR;
        }
    }

    function _latestRoundData(address feed) internal view returns (
        uint80, int256, uint256, uint256, uint80
    ) {
        (bool success, bytes memory data) = feed.staticcall(
            abi.encodeWithSignature("latestRoundData()")
        );
        require(success, "RiskModule: price feed call failed");
        return abi.decode(data, (uint80, int256, uint256, uint256, uint80));
    }

    function _feedDecimals(address feed) internal view returns (uint8) {
        (bool success, bytes memory data) = feed.staticcall(
            abi.encodeWithSignature("decimals()")
        );
        require(success, "RiskModule: decimals call failed");
        return abi.decode(data, (uint8));
    }
}
