// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "../../utils/ReentrancyGuardUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ILiquidationEngine} from "../../interfaces/ILiquidationEngine.sol";
import {ICentuari} from "../../interfaces/ICentuari.sol";
import {IBalanceLedger} from "../../interfaces/IBalanceLedger.sol";
import {IRiskModule} from "../../interfaces/IRiskModule.sol";
import {IPriceOracle} from "../../interfaces/IPriceOracle.sol";
import {LiquidationEngineStorage} from "./LiquidationEngineStorage.sol";

/// @title LiquidationEngine
/// @notice Permissionless liquidation of unhealthy or defaulted Centuari positions.
/// @dev Upgradeable (ERC1967). Must be authorized as a BalanceLedger writer (to seize
///      collateral) and set as Centuari's liquidationEngine (to reduce debt via
///      liquidationRepay). Triggers: HF < 1 (IRiskModule.isLiquidatable) OR a market
///      past maturity with debt outstanding. The liquidator funds the repayment from
///      their own BalanceLedger `available` loan-token balance and receives the seized
///      collateral plus a bonus into their `available`. No ERC20 transfers occur on the
///      path — it is pure BalanceLedger accounting — but the nonReentrant guard is kept.
contract LiquidationEngine is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    LiquidationEngineStorage,
    ILiquidationEngine
{
    uint256 internal constant BPS = 1e4;

    /// @dev Linearity probe for inverting the oracle's amount→USD map (USD→base units).
    ///      OracleRouter.tryGetUsdValue(asset, amount) == amount * price / 10**dec is
    ///      linear in amount, so amount = usd * PROBE / usdValue(PROBE) recovers base
    ///      units without reading token decimals (provider-agnostic, decimals-safe).
    uint256 private constant PROBE = 1e18;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param owner_ Governance owner
    /// @param centuari_ Centuari (debt + liquidationRepay)
    /// @param balanceLedger_ BalanceLedger (collateral seizure)
    /// @param riskModule_ RiskModule (HF trigger)
    /// @param oracle_ Price oracle (IPriceOracle)
    /// @param defaultLiquidationBonusBps_ Default liquidation bonus (bps, ≤ BPS)
    /// @param hfCloseFactorBps_ Close factor for HF liquidations (bps, (0, BPS])
    /// @param maturedCloseFactorBps_ Close factor for matured liquidations (bps, (0, BPS])
    /// @param pauser_ Guardian for the emergency pause
    function initialize(
        address owner_,
        address centuari_,
        address balanceLedger_,
        address riskModule_,
        address oracle_,
        uint256 defaultLiquidationBonusBps_,
        uint256 hfCloseFactorBps_,
        uint256 maturedCloseFactorBps_,
        address pauser_
    ) external initializer {
        if (
            owner_ == address(0) || centuari_ == address(0) || balanceLedger_ == address(0) || riskModule_ == address(0)
                || oracle_ == address(0) || pauser_ == address(0)
        ) revert ZeroAddress();
        if (defaultLiquidationBonusBps_ > BPS) revert InvalidBps();
        if (hfCloseFactorBps_ == 0 || hfCloseFactorBps_ > BPS) revert InvalidBps();
        if (maturedCloseFactorBps_ == 0 || maturedCloseFactorBps_ > BPS) revert InvalidBps();

        __Ownable_init(owner_);
        __ReentrancyGuard_init();

        _centuari = centuari_;
        _balanceLedger = balanceLedger_;
        _riskModule = riskModule_;
        _oracle = oracle_;
        _defaultLiquidationBonusBps = defaultLiquidationBonusBps_;
        _hfCloseFactorBps = hfCloseFactorBps_;
        _maturedCloseFactorBps = maturedCloseFactorBps_;
        _pauser = pauser_;

        emit RiskModuleUpdated(address(0), riskModule_);
        emit OracleUpdated(address(0), oracle_);
        emit DefaultLiquidationBonusUpdated(0, defaultLiquidationBonusBps_);
        emit HfCloseFactorUpdated(0, hfCloseFactorBps_);
        emit MaturedCloseFactorUpdated(0, maturedCloseFactorBps_);
    }

    // ============ Modifiers ============

    modifier whenNotPaused() {
        if (_paused) revert ContractPaused();
        _;
    }

    modifier onlyPauser() {
        if (msg.sender != _pauser) revert Unauthorized();
        _;
    }

    // ============ Core ============

    /// @inheritdoc ILiquidationEngine
    function liquidate(
        address borrower,
        address loanToken,
        uint256 maturity,
        address collateralAsset,
        uint256 repayLoanAmount,
        uint256 minCollateralOut
    ) external whenNotPaused nonReentrant returns (uint256 repaid, uint256 collateralSeized) {
        if (borrower == address(0) || loanToken == address(0) || collateralAsset == address(0)) {
            revert ZeroAddress();
        }
        if (repayLoanAmount == 0) revert NothingToRepay();

        ICentuari centuari_ = ICentuari(_centuari);
        bytes32 marketId = centuari_.getMarketId(loanToken, maturity);

        uint256 debt = centuari_.getBorrowPosition(marketId, borrower);
        if (debt == 0) revert NoDebt();

        // ---- Trigger: matured-with-debt OR account HF < 1 ----
        bool viaMaturity = block.timestamp >= maturity;
        if (!viaMaturity && !IRiskModule(_riskModule).isLiquidatable(borrower)) {
            revert NotLiquidatable();
        }

        // ---- Close-factor cap (matured allows up to 100%; HF is partial) ----
        uint256 closeFactor = viaMaturity ? _maturedCloseFactorBps : _hfCloseFactorBps;
        uint256 maxRepay = Math.mulDiv(debt, closeFactor, BPS); // ≤ debt since closeFactor ≤ BPS
        repaid = repayLoanAmount > maxRepay ? maxRepay : repayLoanAmount;
        if (repaid == 0) revert NothingToRepay();

        // ---- Collateral must be flagged ----
        IBalanceLedger ledger = IBalanceLedger(_balanceLedger);
        if (!ledger.usedAsCollateral(borrower, collateralAsset)) revert CollateralNotFlagged();

        // ---- Price the repay and size the seize (incl. bonus) ----
        uint256 bonusBps = _liquidationBonusBps[collateralAsset];
        if (bonusBps == 0) bonusBps = _defaultLiquidationBonusBps;

        (uint256 repayUsd, bool okR) = IPriceOracle(_oracle).tryGetUsdValue(loanToken, repaid);
        if (!okR || repayUsd == 0) revert LoanTokenUnpriced();

        uint256 seizeUsd = repayUsd + Math.mulDiv(repayUsd, bonusBps, BPS);
        collateralSeized = _usdToBaseUnits(collateralAsset, seizeUsd);

        // ---- Bad-debt cap: never seize more than the borrower holds ----
        bool cappedByCollateral = false;
        uint256 availColl = ledger.available(borrower, collateralAsset);
        if (collateralSeized > availColl) {
            cappedByCollateral = true;
            collateralSeized = availColl;
            // Back out the repay the capped collateral can actually support.
            (uint256 cappedUsd, bool okC) = IPriceOracle(_oracle).tryGetUsdValue(collateralAsset, collateralSeized);
            if (!okC) revert CollateralUnpriced();
            uint256 supportedRepayUsd = Math.mulDiv(cappedUsd, BPS, BPS + bonusBps);
            repaid = _usdToBaseUnits(loanToken, supportedRepayUsd);
            if (repaid > debt) repaid = debt;
            if (repaid == 0) revert NothingToRepay();
        }

        if (collateralSeized == 0) revert NothingToRepay();
        if (collateralSeized < minCollateralOut) revert SlippageExceeded();

        // ---- Effects: repay leg (Centuari, debits the liquidator) then seize leg ----
        centuari_.liquidationRepay(marketId, borrower, loanToken, msg.sender, repaid);

        ledger.debit(borrower, collateralAsset, collateralSeized);
        ledger.credit(msg.sender, collateralAsset, collateralSeized);

        // Auto-unmark fully-drained collateral so it stops counting toward HF.
        if (ledger.available(borrower, collateralAsset) == 0) {
            ledger.unmarkCollateral(borrower, collateralAsset);
        }

        emit Liquidated(
            borrower, msg.sender, marketId, loanToken, collateralAsset, repaid, collateralSeized, viaMaturity
        );

        if (cappedByCollateral) {
            uint256 remaining = centuari_.getBorrowPosition(marketId, borrower);
            if (remaining > 0) emit BadDebtRemains(borrower, marketId, remaining);
        }
    }

    // ============ Internal ============

    /// @notice Convert a 1e18 USD value into base units of `asset` using the oracle's
    ///         own linearity, avoiding any new oracle surface.
    /// @dev usdValue(amount) = amount·probeUsd/PROBE ⇒ amount = usd·PROBE/probeUsd.
    ///      Decimals-safe (never reads token decimals) and floors (favors the borrower).
    function _usdToBaseUnits(address asset, uint256 usd1e18) internal view returns (uint256) {
        if (usd1e18 == 0) return 0;
        (uint256 probeUsd, bool ok) = IPriceOracle(_oracle).tryGetUsdValue(asset, PROBE);
        if (!ok || probeUsd == 0) revert CollateralUnpriced();
        return Math.mulDiv(usd1e18, PROBE, probeUsd);
    }

    // ============ Governance ============

    function setRiskModule(address newRiskModule) external onlyOwner {
        if (newRiskModule == address(0)) revert ZeroAddress();
        emit RiskModuleUpdated(_riskModule, newRiskModule);
        _riskModule = newRiskModule;
    }

    function setOracle(address newOracle) external onlyOwner {
        if (newOracle == address(0)) revert ZeroAddress();
        emit OracleUpdated(_oracle, newOracle);
        _oracle = newOracle;
    }

    function setDefaultLiquidationBonus(uint256 bps) external onlyOwner {
        if (bps > BPS) revert InvalidBps();
        emit DefaultLiquidationBonusUpdated(_defaultLiquidationBonusBps, bps);
        _defaultLiquidationBonusBps = bps;
    }

    function setLiquidationBonus(address collateralAsset, uint256 bps) external onlyOwner {
        if (collateralAsset == address(0)) revert ZeroAddress();
        if (bps > BPS) revert InvalidBps();
        emit LiquidationBonusUpdated(collateralAsset, _liquidationBonusBps[collateralAsset], bps);
        _liquidationBonusBps[collateralAsset] = bps;
    }

    function setHfCloseFactor(uint256 bps) external onlyOwner {
        if (bps == 0 || bps > BPS) revert InvalidBps();
        emit HfCloseFactorUpdated(_hfCloseFactorBps, bps);
        _hfCloseFactorBps = bps;
    }

    function setMaturedCloseFactor(uint256 bps) external onlyOwner {
        if (bps == 0 || bps > BPS) revert InvalidBps();
        emit MaturedCloseFactorUpdated(_maturedCloseFactorBps, bps);
        _maturedCloseFactorBps = bps;
    }

    function setPauser(address newPauser) external onlyOwner {
        if (newPauser == address(0)) revert ZeroAddress();
        emit PauserUpdated(_pauser, newPauser);
        _pauser = newPauser;
    }

    function pause() external onlyPauser {
        _paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyPauser {
        _paused = false;
        emit Unpaused(msg.sender);
    }

    // ============ Views ============

    function centuari() external view returns (address) {
        return _centuari;
    }

    function balanceLedger() external view returns (address) {
        return _balanceLedger;
    }

    function riskModule() external view returns (address) {
        return _riskModule;
    }

    function oracle() external view returns (address) {
        return _oracle;
    }

    function hfCloseFactorBps() external view returns (uint256) {
        return _hfCloseFactorBps;
    }

    function maturedCloseFactorBps() external view returns (uint256) {
        return _maturedCloseFactorBps;
    }

    function defaultLiquidationBonusBps() external view returns (uint256) {
        return _defaultLiquidationBonusBps;
    }

    function liquidationBonusBps(address collateralAsset) external view returns (uint256) {
        return _liquidationBonusBps[collateralAsset];
    }

    function paused() external view returns (bool) {
        return _paused;
    }

    function pauser() external view returns (address) {
        return _pauser;
    }
}
