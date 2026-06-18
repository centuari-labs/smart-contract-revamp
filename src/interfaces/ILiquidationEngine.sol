// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ILiquidationEngine
/// @notice Permissionless liquidation entry point for Centuari positions.
/// @dev A position is liquidatable when EITHER the borrower's account-level health
///      factor is below 1 (HF trigger, via `IRiskModule.isLiquidatable`) OR a
///      specific market's loan has passed maturity with debt outstanding (default
///      trigger). Anyone may liquidate: the caller funds the repayment from their
///      own BalanceLedger `available` loan-token balance and receives the seized
///      collateral plus a liquidation bonus into their `available`.
interface ILiquidationEngine {
    // ============ Events ============

    /// @notice Emitted on a successful liquidation
    /// @param borrower The liquidated borrower
    /// @param liquidator The account that funded the repayment and received collateral
    /// @param marketId The market whose debt was reduced
    /// @param loanToken The loan token repaid
    /// @param collateralAsset The collateral asset seized
    /// @param repaid The loan-token amount actually repaid
    /// @param collateralSeized The collateral amount transferred to the liquidator
    /// @param viaMaturity True if triggered by maturity/default, false if by HF
    event Liquidated(
        address indexed borrower,
        address indexed liquidator,
        bytes32 indexed marketId,
        address loanToken,
        address collateralAsset,
        uint256 repaid,
        uint256 collateralSeized,
        bool viaMaturity
    );

    /// @notice Emitted when the seizure was capped by the borrower's available
    ///         collateral and debt still remains (bad debt for this market)
    /// @param borrower The borrower with residual debt
    /// @param marketId The affected market
    /// @param remainingDebt The debt still outstanding after the liquidation
    event BadDebtRemains(address indexed borrower, bytes32 indexed marketId, uint256 remainingDebt);

    event RiskModuleUpdated(address indexed oldRiskModule, address indexed newRiskModule);
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);
    event DefaultLiquidationBonusUpdated(uint256 oldBps, uint256 newBps);
    event LiquidationBonusUpdated(address indexed collateralAsset, uint256 oldBps, uint256 newBps);
    event HfCloseFactorUpdated(uint256 oldBps, uint256 newBps);
    event MaturedCloseFactorUpdated(uint256 oldBps, uint256 newBps);
    event PauserUpdated(address indexed oldPauser, address indexed newPauser);
    event Paused(address account);
    event Unpaused(address account);

    // ============ Errors ============

    error ZeroAddress();
    error InvalidBps();
    error ContractPaused();
    error Unauthorized();
    error NoDebt();
    error NotLiquidatable();
    error CollateralNotFlagged();
    error LoanTokenUnpriced();
    error CollateralUnpriced();
    error NothingToRepay();
    error SlippageExceeded();

    // ============ Core ============

    /// @notice Liquidate part of `borrower`'s debt in (loanToken, maturity), seizing
    ///         `collateralAsset` at a bonus. The caller is the liquidator and funds
    ///         the repayment from their own BalanceLedger `available` balance.
    /// @param borrower The under-collateralized / defaulted borrower
    /// @param loanToken The loan token of the market being repaid
    /// @param maturity The maturity of the market being repaid
    /// @param collateralAsset The flagged collateral asset to seize
    /// @param repayLoanAmount The desired loan-token repay (capped by close factor / debt / collateral)
    /// @param minCollateralOut Slippage floor: revert if seized collateral is below this
    /// @return repaid The loan-token amount actually repaid
    /// @return collateralSeized The collateral amount transferred to the liquidator
    function liquidate(
        address borrower,
        address loanToken,
        uint256 maturity,
        address collateralAsset,
        uint256 repayLoanAmount,
        uint256 minCollateralOut
    ) external returns (uint256 repaid, uint256 collateralSeized);

    // ============ Views ============

    function centuari() external view returns (address);
    function balanceLedger() external view returns (address);
    function riskModule() external view returns (address);
    function oracle() external view returns (address);
    function hfCloseFactorBps() external view returns (uint256);
    function maturedCloseFactorBps() external view returns (uint256);
    function defaultLiquidationBonusBps() external view returns (uint256);
    function liquidationBonusBps(address collateralAsset) external view returns (uint256);
    function paused() external view returns (bool);
    function pauser() external view returns (address);
}
