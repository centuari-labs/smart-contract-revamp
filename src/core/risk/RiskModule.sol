// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IRiskModule} from "../../interfaces/IRiskModule.sol";
import {IPriceOracle} from "../../interfaces/IPriceOracle.sol";
import {ICentuari} from "../../interfaces/ICentuari.sol";
import {IBalanceLedger} from "../../interfaces/IBalanceLedger.sol";
import {RiskModuleStorage} from "./RiskModuleStorage.sol";

/// @title RiskModule
/// @notice Oracle-backed health-factor (HF) policy implementing `IRiskModule`.
/// @dev Replaces `RiskModuleStub` behind the SAME `IRiskModule` seam — swapped
///      in by governance via `setRiskModule` on `WithdrawalRegistry` and
///      `CollateralManager`, so no caller contract changes. Mirrors the
///      off-chain HF math (backend PortfolioService):
///
///        weightedLTV = Σ(cVal·ltv) / Σ cVal     over post-action flagged collateral
///        HF          = (collateralUsd − debtUsd) · weightedLTV / debtUsd
///        pass iff HF ≥ 1e18 + maxBufferBps·1e18/1e4
///
///      All USD values are 1e18-scaled. FAIL-CLOSED: if any required price is
///      missing or stale (oracle returns ok == false) the check returns `false`.
///      Per the `IRiskModule` contract, the decision path never reverts.
contract RiskModule is Initializable, OwnableUpgradeable, RiskModuleStorage, IRiskModule {
    uint256 internal constant ONE = 1e18;
    uint256 internal constant BPS = 1e4;

    event OracleUpdated(address indexed oldOracle, address indexed newOracle);
    event LtvUpdated(address indexed asset, uint256 oldBps, uint256 newBps);
    event BufferUpdated(address indexed asset, uint256 oldBps, uint256 newBps);
    event DefaultBufferUpdated(uint256 oldBps, uint256 newBps);

    error ZeroAddress();
    error InvalidBps();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param owner_ Governance owner
    /// @param oracle_ Provider-agnostic USD price oracle
    /// @param centuari_ Centuari (per-user debt source)
    /// @param balanceLedger_ BalanceLedger (collateral + balances source)
    function initialize(address owner_, address oracle_, address centuari_, address balanceLedger_)
        external
        initializer
    {
        if (owner_ == address(0)) revert ZeroAddress();
        if (oracle_ == address(0)) revert ZeroAddress();
        if (centuari_ == address(0)) revert ZeroAddress();
        if (balanceLedger_ == address(0)) revert ZeroAddress();

        __Ownable_init(owner_);
        _oracle = IPriceOracle(oracle_);
        _centuari = ICentuari(centuari_);
        _balanceLedger = IBalanceLedger(balanceLedger_);
        _defaultBufferBps = 100; // mirrors off-chain DEFAULT_BORROW_BUFFER_BPS (1.01)

        emit OracleUpdated(address(0), oracle_);
        emit DefaultBufferUpdated(0, 100);
    }

    // ============ Governance ============

    /// @notice Swap the price oracle (provider-agnostic; any `IPriceOracle`).
    function setOracle(address newOracle) external onlyOwner {
        if (newOracle == address(0)) revert ZeroAddress();
        address old = address(_oracle);
        _oracle = IPriceOracle(newOracle);
        emit OracleUpdated(old, newOracle);
    }

    /// @notice Set a collateral asset's LTV (basis points, ≤ 10000).
    function setLtv(address asset, uint256 ltvBps_) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        if (ltvBps_ > BPS) revert InvalidBps();
        uint256 old = _ltvBps[asset];
        _ltvBps[asset] = ltvBps_;
        emit LtvUpdated(asset, old, ltvBps_);
    }

    /// @notice Set a collateral asset's HF buffer (basis points, ≤ 10000; 0 = use default).
    function setBuffer(address asset, uint256 bufferBps_) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        if (bufferBps_ > BPS) revert InvalidBps();
        uint256 old = _bufferBps[asset];
        _bufferBps[asset] = bufferBps_;
        emit BufferUpdated(asset, old, bufferBps_);
    }

    /// @notice Set the default HF buffer used when an asset has no explicit buffer.
    function setDefaultBuffer(uint256 bufferBps_) external onlyOwner {
        if (bufferBps_ > BPS) revert InvalidBps();
        uint256 old = _defaultBufferBps;
        _defaultBufferBps = bufferBps_;
        emit DefaultBufferUpdated(old, bufferBps_);
    }

    // ============ IRiskModule ============

    /// @inheritdoc IRiskModule
    function canWithdraw(address user, address asset, uint256 amount) external view returns (bool) {
        // Withdrawing a non-collateral asset can never reduce the user's HF.
        if (!_balanceLedger.usedAsCollateral(user, asset)) return true;
        return _healthyAfter(user, asset, amount, false);
    }

    /// @inheritdoc IRiskModule
    function canUnflag(address user, address asset) external view returns (bool) {
        return _healthyAfter(user, asset, 0, true);
    }

    // ============ Internal HF math ============

    /// @notice True iff the user's post-action health factor ≥ threshold.
    /// @dev `actedAsset` is reduced by `withdrawAmount` (withdraw) or removed
    ///      from collateral entirely (`removeEntirely` == unflag). Fail-closed on
    ///      any unpriced/stale input. Never reverts on the decision path.
    function _healthyAfter(address user, address actedAsset, uint256 withdrawAmount, bool removeEntirely)
        internal
        view
        returns (bool)
    {
        IBalanceLedger bl = _balanceLedger;
        IPriceOracle px = _oracle;

        // SC-6: read debt FIRST. A user with no active debt is always healthy and
        // must never be fail-closed out of withdraw/unflag by a stale/unpriced
        // *collateral* feed. Pricing collateral first (the old order) blocked
        // debt-free users whenever a collateral price was stale. Reading debt up
        // front is also the gas fast-path — it skips every collateral oracle call
        // for the common no-debt case. Debt is already deduped per loan token by
        // getBorrowerDebts (one oracle call per distinct loan token), which covers
        // the SC-5 "dedup oracle calls per loan token" recommendation.
        (address[] memory debtTokens, uint256[] memory debtAmounts) = _centuari.getBorrowerDebts(user);
        if (debtTokens.length == 0) return true; // no active debt markets → healthy

        uint256 debtUsd;
        for (uint256 j = 0; j < debtTokens.length; ++j) {
            if (debtAmounts[j] == 0) continue;
            (uint256 dVal, bool ok2) = px.tryGetUsdValue(debtTokens[j], debtAmounts[j]);
            if (!ok2) return false; // fail-closed: unpriced/stale debt
            debtUsd += dVal;
        }
        if (debtUsd == 0) return true; // no debt → always healthy

        // There IS debt: now value the post-action flagged collateral.
        address[] memory flagged = bl.flaggedAssetsOf(user);

        uint256 collateralUsd; // Σ cVal (1e18)
        uint256 ltvWeighted; // Σ cVal·ltvBps/1e4 (== collateralUsd · weightedLTV)
        uint256 maxBufferBps;

        for (uint256 i = 0; i < flagged.length; ++i) {
            address c = flagged[i];

            uint256 amt = bl.available(user, c);
            if (c == actedAsset) {
                if (removeEntirely) continue; // unflag: drops out of collateral
                amt = amt > withdrawAmount ? amt - withdrawAmount : 0;
            }
            if (amt == 0) continue;

            (uint256 cVal, bool ok) = px.tryGetUsdValue(c, amt);
            if (!ok) return false; // fail-closed: unpriced/stale collateral

            collateralUsd += cVal;
            ltvWeighted += Math.mulDiv(cVal, _ltvBps[c], BPS);

            uint256 b = _bufferBps[c];
            if (b == 0) b = _defaultBufferBps;
            if (b > maxBufferBps) maxBufferBps = b;
        }

        if (collateralUsd <= debtUsd) return false; // net ≤ 0 → HF ≤ 0 < threshold

        uint256 net = collateralUsd - debtUsd;
        // HF1e18 = net · (ltvWeighted / collateralUsd) · 1e18 / debtUsd
        uint256 hf = Math.mulDiv(net, ltvWeighted, collateralUsd);
        hf = Math.mulDiv(hf, ONE, debtUsd);

        uint256 threshold = ONE + Math.mulDiv(maxBufferBps, ONE, BPS);
        return hf >= threshold;
    }

    // ============ Views ============

    function oracle() external view returns (address) {
        return address(_oracle);
    }

    function centuari() external view returns (address) {
        return address(_centuari);
    }

    function balanceLedger() external view returns (address) {
        return address(_balanceLedger);
    }

    function ltvBps(address asset) external view returns (uint256) {
        return _ltvBps[asset];
    }

    function bufferBps(address asset) external view returns (uint256) {
        return _bufferBps[asset];
    }

    function defaultBufferBps() external view returns (uint256) {
        return _defaultBufferBps;
    }
}
