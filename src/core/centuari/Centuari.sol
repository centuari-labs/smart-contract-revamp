// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    Initializable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {
    ReentrancyGuardUpgradeable
} from "../../utils/ReentrancyGuardUpgradeable.sol";

import {ICentuari} from "../../interfaces/ICentuari.sol";
import {IBalanceLedger} from "../../interfaces/IBalanceLedger.sol";
import {CentuariStorage} from "./CentuariStorage.sol";
import {CentuariBondERC20Factory} from "./CentuariBondERC20Factory.sol";
import {CentuariBondERC20} from "./CentuariBondERC20.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Centuari
/// @notice Manages lending and borrowing positions for fixed-rate markets
/// @dev This contract handles position accounting, share calculations, and coordinates with BalanceLedger for balance mutations.
///      It is designed to be deployed behind an ERC1967 proxy for upgradeability.
///      Markets are identified by (loanToken, maturity) pairs.
contract Centuari is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    CentuariStorage,
    ICentuari
{
    // ============ Constructor ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initializer ============

    /// @notice Initialize the Centuari contract
    /// @dev Can only be called once. Sets owner, settlement, balanceLedger, and feeCollector addresses.
    /// @param owner_ The owner address (can update settings)
    /// @param settlement_ The Settlement contract address
    /// @param balanceLedger_ The BalanceLedger contract address
    /// @param feeCollector_ The address that receives protocol fee credits
    function initialize(
        address owner_,
        address settlement_,
        address balanceLedger_,
        address feeCollector_
    ) external initializer {
        if (owner_ == address(0)) revert ZeroAddress();
        if (settlement_ == address(0)) revert ZeroAddress();
        if (balanceLedger_ == address(0)) revert ZeroAddress();
        if (feeCollector_ == address(0)) revert ZeroAddress();

        __Ownable_init(owner_);
        __ReentrancyGuard_init();

        _settlement = settlement_;
        _balanceLedger = balanceLedger_;
        _feeCollector = feeCollector_;
        _paused = false;

        emit SettlementUpdated(address(0), settlement_);
        emit BalanceLedgerUpdated(address(0), balanceLedger_);
    }

    // ============ Modifiers ============

    /// @notice Restricts function access to the Settlement contract
    modifier onlySettlement() {
        if (msg.sender != _settlement) revert Unauthorized();
        _;
    }

    /// @notice Ensures the contract is not paused
    modifier whenNotPaused() {
        if (_paused) revert ContractPaused();
        _;
    }

    /// @notice Restricts function access to the operator (backend)
    modifier onlyOperator() {
        if (msg.sender != _operator) revert Unauthorized();
        _;
    }

    // ============ Core Settlement Function ============

    /// @inheritdoc ICentuari
    function settleMatch(
        bytes32 marketId,
        address lender,
        address borrower,
        address loanToken,
        uint256 matchedAmount,
        uint256 rate,
        uint256 maturity,
        bool borrowerIsTaker,
        uint256 lenderSettlementFee,
        uint256 borrowerSettlementFee,
        uint256 makerFeeAmount,
        uint256 takerFeeAmount,
        address[] calldata collateralAssets
    ) external onlySettlement whenNotPaused nonReentrant {
        // Validate inputs
        if (matchedAmount == 0) revert InvalidAmount();
        if (maturity <= block.timestamp) revert InvalidMaturity();

        if (_marketTotalCbt[marketId] == 0) {
            emit MarketCreated(marketId, loanToken, maturity);
        }

        // Determine lender and borrower fees based on maker/taker roles
        uint256 lenderFee;
        uint256 borrowerFee;
        if (borrowerIsTaker) {
            lenderFee = makerFeeAmount;
            borrowerFee = takerFeeAmount;
        } else {
            lenderFee = takerFeeAmount;
            borrowerFee = makerFeeAmount;
        }

        address bondToken = address(0);
        if (_bondTokenFactory != address(0)) {
            bondToken = CentuariBondERC20Factory(_bondTokenFactory).getOrCreate(
                loanToken,
                maturity
            );
        }

        uint256 cbtAmount = _processLendPosition(
            marketId,
            lender,
            matchedAmount,
            rate,
            maturity,
            bondToken
        );

        // Capture whether this is a new debt market for the borrower before processing
        bool isNewDebtMarket = (_borrowDebt[marketId][borrower] == 0);

        _processBorrowPosition(
            marketId,
            borrower,
            matchedAmount,
            rate,
            maturity
        );

        // Track active debt count (used for debt-state views/health checks)
        if (isNewDebtMarket) {
            _activeDebtCount[borrower]++;
        }

        // Balance mutations via BalanceLedger
        uint256 totalLenderFee = lenderSettlementFee + lenderFee;
        uint256 totalBorrowerFee = borrowerSettlementFee + borrowerFee;

        IBalanceLedger(_balanceLedger).debit(lender, loanToken, matchedAmount + totalLenderFee);
        IBalanceLedger(_balanceLedger).credit(borrower, loanToken, matchedAmount);

        if (totalBorrowerFee > 0) {
            IBalanceLedger(_balanceLedger).debit(borrower, loanToken, totalBorrowerFee);
        }

        // Protocol fee collection
        uint256 totalProtocolFees = totalLenderFee + totalBorrowerFee;
        if (totalProtocolFees > 0) {
            IBalanceLedger(_balanceLedger).credit(_feeCollector, loanToken, totalProtocolFees);
        }

        // Fulfill borrower's explicit flag-as-collateral requests (empty array = no-op).
        // markCollateral is idempotent in BalanceLedger: re-submitting an already-flagged
        // asset does NOT refresh _flaggedAt (load-bearing for the 24h flag-lock).
        for (uint256 i = 0; i < collateralAssets.length; ++i) {
            IBalanceLedger(_balanceLedger).markCollateral(borrower, collateralAssets[i]);
        }

        // Mint CBT to Centuari (bond custodian)
        if (bondToken != address(0) && cbtAmount > 0) {
            CentuariBondERC20(bondToken).mint(address(this), cbtAmount);
        }
    }

    // ============ Internal Functions ============

    /// @notice Process the lender's position (fixed-rate CBT = principal + day-count interest)
    /// @param marketId The market identifier
    /// @param lender The lender address
    /// @param principal The matched principal amount (CBT is based on full principal; fees are deducted from balance by BalanceLedger)
    /// @param rate The interest rate in basis points
    /// @param maturity The maturity timestamp
    /// @param bondToken The CBT (bond token) contract address for the market
    /// @return cbtAmount The CBT (claim at maturity) issued to the lender
    function _processLendPosition(
        bytes32 marketId,
        address lender,
        uint256 principal,
        uint256 rate,
        uint256 maturity,
        address bondToken
    ) internal returns (uint256 cbtAmount) {
        cbtAmount =
            principal +
            _interestWithDayCount(
                principal,
                rate,
                block.timestamp,
                maturity
            );

        _marketTotalCbt[marketId] += cbtAmount;
        _lendPositionCbtAmount[marketId][lender] += cbtAmount;

        emit LendPositionCreated(
            marketId,
            lender,
            bondToken,
            cbtAmount,
            principal,
            rate
        );
    }

    /// @notice Process the borrower's position
    /// @param marketId The market identifier
    /// @param borrower The borrower address
    /// @param principal The principal amount being borrowed
    /// @param rate The interest rate in basis points
    /// @param maturity The maturity timestamp
    function _processBorrowPosition(
        bytes32 marketId,
        address borrower,
        uint256 principal,
        uint256 rate,
        uint256 maturity
    ) internal {
        uint256 debt = principal +
            _interestWithDayCount(principal, rate, block.timestamp, maturity);
        _borrowDebt[marketId][borrower] += debt;

        emit BorrowPositionCreated(marketId, borrower, principal, debt, rate);
    }

    // ============ Repay Function ============

    /// @inheritdoc ICentuari
    function repay(
        bytes32 marketId,
        address borrower,
        address loanToken,
        uint256 amount
    ) external onlyOperator whenNotPaused nonReentrant {
        if (borrower == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();

        uint256 debt = _borrowDebt[marketId][borrower];

        if (debt == 0) revert InvalidAmount();

        uint256 repayAmount = amount > debt ? debt : amount;
        if (repayAmount == 0) revert InvalidAmount();

        _borrowDebt[marketId][borrower] = debt - repayAmount;

        // Track active debt count: decrement when this market's debt hits zero
        if (debt - repayAmount == 0) {
            _activeDebtCount[borrower]--;
        }

        // Debit borrower's available balance (no credit — repaid tokens are protocol-unallocated)
        IBalanceLedger(_balanceLedger).debit(borrower, loanToken, repayAmount);

        // Note: repay never touches collateral flags. Users unflag explicitly via
        // CollateralManager.unflagFor, which enforces the 24h flag-lock and RiskModule gate.

        emit Repaid(marketId, borrower, repayAmount);
    }

    /// @inheritdoc ICentuari
    /// @dev `cbtAmount` is denominated in CBT units, which are 1:1 with the
    ///      withdrawable loan token amount at maturity for this market.
    function withdrawLendPosition(
        bytes32 marketId,
        address loanToken,
        uint256 maturity,
        uint256 cbtAmount
    ) external whenNotPaused nonReentrant {
        if (cbtAmount == 0) revert InvalidAmount();
        if (_bondTokenFactory == address(0)) revert BondTokenNotFound();

        address bondToken = CentuariBondERC20Factory(_bondTokenFactory)
            .getBondToken(loanToken, maturity);
        if (bondToken == address(0)) revert BondTokenNotFound();

        if (block.timestamp < maturity) revert NotYetMatured();

        if (_lendPositionCbtAmount[marketId][msg.sender] < cbtAmount)
            revert InvalidAmount();
        if (_marketTotalCbt[marketId] < cbtAmount) revert InvalidAmount();

        // Burn bonds from Centuari's own custody
        CentuariBondERC20(bondToken).burn(cbtAmount);

        _lendPositionCbtAmount[marketId][msg.sender] -= cbtAmount;
        _marketTotalCbt[marketId] -= cbtAmount;

        // Credit lender's available balance in BalanceLedger
        IBalanceLedger(_balanceLedger).credit(msg.sender, loanToken, cbtAmount);

        emit LendPositionWithdrawn(marketId, msg.sender, cbtAmount, cbtAmount);
    }

    /// @notice Interest using day-count convention: start+1 = day 1, maturity-1 = last day (e.g. Jan 1 -> Feb 1 = 30 days)
    /// @param principal The principal amount
    /// @param rate The interest rate in basis points (e.g., 1000 = 10%)
    /// @param start The settlement/start timestamp
    /// @param maturity The maturity timestamp
    /// @return interest The calculated interest amount
    function _interestWithDayCount(
        uint256 principal,
        uint256 rate,
        uint256 start,
        uint256 maturity
    ) internal pure returns (uint256 interest) {
        uint256 rawDays = (maturity - start) / 1 days;
        uint256 days_ = rawDays > 0 ? rawDays - 1 : 0;
        interest = Math.mulDiv(
            Math.mulDiv(principal, rate, RATE_PRECISION),
            days_,
            365
        );
    }

    /// @notice Calculate market ID from loan token and maturity
    /// @param loanToken The loan token address
    /// @param maturity The maturity timestamp
    /// @return The market ID
    function _getMarketId(
        address loanToken,
        uint256 maturity
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(loanToken, maturity));
    }

    // ============ Administrative Functions ============

    /// @notice Update the Settlement contract address
    /// @dev Only callable by owner
    /// @param newSettlement The new Settlement contract address
    function setSettlement(address newSettlement) external onlyOwner {
        if (newSettlement == address(0)) revert ZeroAddress();

        address oldSettlement = _settlement;
        _settlement = newSettlement;

        emit SettlementUpdated(oldSettlement, newSettlement);
    }

    /// @notice Update the BalanceLedger contract address
    /// @dev Only callable by owner
    /// @param newBalanceLedger The new BalanceLedger contract address
    function setBalanceLedger(address newBalanceLedger) external onlyOwner {
        if (newBalanceLedger == address(0)) revert ZeroAddress();

        address oldBalanceLedger = _balanceLedger;
        _balanceLedger = newBalanceLedger;

        emit BalanceLedgerUpdated(oldBalanceLedger, newBalanceLedger);
    }

    /// @notice Update the fee collector address
    /// @dev Only callable by owner
    /// @param newFeeCollector The new fee collector address
    function setFeeCollector(address newFeeCollector) external onlyOwner {
        if (newFeeCollector == address(0)) revert ZeroAddress();

        address oldFeeCollector = _feeCollector;
        _feeCollector = newFeeCollector;

        emit FeeCollectorUpdated(oldFeeCollector, newFeeCollector);
    }

    /// @notice Update the Bond Token Factory contract address
    /// @dev Only callable by owner
    /// @param newFactory The new Bond Token Factory contract address
    function setBondTokenFactory(address newFactory) external onlyOwner {
        if (newFactory == address(0)) revert ZeroAddress();

        address oldFactory = _bondTokenFactory;
        _bondTokenFactory = newFactory;

        emit BondTokenFactoryUpdated(oldFactory, newFactory);
    }

    /// @notice Pause the contract
    /// @dev Only callable by owner. Prevents settlement functions from executing.
    function pause() external onlyOwner {
        _paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Unpause the contract
    /// @dev Only callable by owner. Allows settlement functions to execute.
    function unpause() external onlyOwner {
        _paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Update the operator (backend) address
    /// @dev Only callable by owner
    /// @param newOperator The new operator address
    function setOperator(address newOperator) external onlyOwner {
        if (newOperator == address(0)) revert ZeroAddress();

        address oldOperator = _operator;
        _operator = newOperator;

        emit OperatorUpdated(oldOperator, newOperator);
    }

    // ============ View Functions ============

    /// @inheritdoc ICentuari
    function getMarketId(
        address loanToken,
        uint256 maturity
    ) external pure returns (bytes32) {
        return _getMarketId(loanToken, maturity);
    }

    /// @inheritdoc ICentuari
    function getMarketTotalCbt(
        bytes32 marketId
    ) external view returns (uint256) {
        return _marketTotalCbt[marketId];
    }

    /// @inheritdoc ICentuari
    function getLendPositionCbtAmount(
        bytes32 marketId,
        address lender
    ) external view returns (uint256) {
        return _lendPositionCbtAmount[marketId][lender];
    }

    /// @inheritdoc ICentuari
    function getBorrowPosition(
        bytes32 marketId,
        address borrower
    ) external view returns (uint256) {
        return _borrowDebt[marketId][borrower];
    }

    /// @inheritdoc ICentuari
    function settlement() external view returns (address) {
        return _settlement;
    }

    /// @inheritdoc ICentuari
    function balanceLedger() external view returns (address) {
        return _balanceLedger;
    }

    /// @inheritdoc ICentuari
    function activeDebtCount(address user) external view returns (uint256) {
        return _activeDebtCount[user];
    }

    /// @inheritdoc ICentuari
    function feeCollector() external view returns (address) {
        return _feeCollector;
    }

    /// @inheritdoc ICentuari
    function paused() external view returns (bool) {
        return _paused;
    }

    /// @inheritdoc ICentuari
    function bondTokenFactory() external view returns (address) {
        return _bondTokenFactory;
    }

    /// @inheritdoc ICentuari
    function operator() external view returns (address) {
        return _operator;
    }
}
