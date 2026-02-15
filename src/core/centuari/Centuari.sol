// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "../../utils/ReentrancyGuardUpgradeable.sol";

import {ICentuari} from "../../interfaces/ICentuari.sol";
import {ITreasury} from "../../interfaces/ITreasury.sol";
import {CentuariStorage} from "./CentuariStorage.sol";
import {CentuariBondERC20Factory} from "./CentuariBondERC20Factory.sol";
import {CentuariBondERC20} from "./CentuariBondERC20.sol";

/// @title Centuari
/// @notice Manages lending and borrowing positions for fixed-rate markets
/// @dev This contract handles position accounting, share calculations, and coordinates with Treasury for transfers.
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
    /// @dev Can only be called once. Sets owner, settlement, and treasury addresses.
    /// @param owner_ The owner address (can update settings)
    /// @param settlement_ The Settlement contract address
    /// @param treasury_ The Treasury contract address
    function initialize(
        address owner_,
        address settlement_,
        address treasury_
    ) external initializer {
        if (owner_ == address(0)) revert ZeroAddress();
        if (settlement_ == address(0)) revert ZeroAddress();
        if (treasury_ == address(0)) revert ZeroAddress();

        __Ownable_init(owner_);
        __ReentrancyGuard_init();

        _settlement = settlement_;
        _treasury = treasury_;
        _paused = false;

        emit SettlementUpdated(address(0), settlement_);
        emit TreasuryUpdated(address(0), treasury_);
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
        address lender, //@todo : change this into account id
        address borrower, //@todo : change this into account id
        address loanToken, //@todo : change this into asset id
        uint256 matchedAmount,
        uint256 rate,
        uint256 maturity,
        bool borrowerIsTaker,
        uint256 lenderSettlementFee,
        uint256 borrowerSettlementFee,
        uint256 makerFeeAmount,
        uint256 takerFeeAmount
    ) external onlySettlement whenNotPaused nonReentrant {
        // Validate inputs
        if (matchedAmount == 0) revert InvalidAmount();
        if (maturity <= block.timestamp) revert InvalidMaturity();

        bytes32 marketId = _getMarketId(loanToken, maturity);

        if (_marketTotalCbt[marketId] == 0) {
            emit MarketCreated(marketId, loanToken, maturity);
        }

        // Determine lender and borrower fees based on maker/taker roles
        // If borrower is taker: borrower pays takerFeeAmount, lender pays makerFeeAmount
        // If borrower is NOT taker (lender is taker): lender pays takerFeeAmount, borrower pays makerFeeAmount
        uint256 lenderFee;
        uint256 borrowerFee;
        if (borrowerIsTaker) {
            lenderFee = makerFeeAmount;
            borrowerFee = takerFeeAmount;
        } else {
            lenderFee = takerFeeAmount;
            borrowerFee = makerFeeAmount;
        }

        uint256 cbtAmount = _processLendPosition(marketId, lender, matchedAmount, lenderFee, rate, maturity);

        // Process borrower position (same day-count so debt = lender CBT for same principal)
        _processBorrowPosition(marketId, borrower, matchedAmount, rate, maturity);

        uint256 netLoanAmountForBorrower = matchedAmount - borrowerFee;

        ITreasury(_treasury).settle(
            loanToken,
            lender,
            borrower,
            netLoanAmountForBorrower,
            lenderSettlementFee,
            borrowerSettlementFee
        );

        if (_bondTokenFactory != address(0) && cbtAmount > 0) {
            address bondToken = CentuariBondERC20Factory(_bondTokenFactory).getOrCreate(
                loanToken,
                maturity
            );
            CentuariBondERC20(bondToken).mint(lender, cbtAmount);
        }
    }

    // ============ Internal Functions ============

    /// @notice Process the lender's position (fixed-rate CBT = effective principal + day-count interest)
    /// @param marketId The market identifier
    /// @param lender The lender address
    /// @param principal The original matched principal (emitted in event)
    /// @param lenderFee The fee deducted from the lender; CBT is based on principal - lenderFee
    /// @param rate The interest rate in basis points
    /// @param maturity The maturity timestamp
    /// @return cbtAmount The CBT (claim at maturity) issued to the lender
    function _processLendPosition(
        bytes32 marketId,
        address lender,
        uint256 principal,
        uint256 lenderFee,
        uint256 rate,
        uint256 maturity
    ) internal returns (uint256 cbtAmount) {
        uint256 effectivePrincipal = principal - lenderFee;
        cbtAmount = effectivePrincipal + _interestWithDayCount(effectivePrincipal, rate, block.timestamp, maturity);

        _marketTotalCbt[marketId] += cbtAmount;
        _lendPositionCbtAmount[marketId][lender] += cbtAmount;

        emit LendPositionCreated(marketId, lender, cbtAmount, principal, rate);
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
        uint256 debt = principal + _interestWithDayCount(principal, rate, block.timestamp, maturity);
        _borrowDebt[marketId][borrower] += debt;

        emit BorrowPositionCreated(marketId, borrower, principal, debt, rate);
    }

    // ============ Repay Function ============

    /// @inheritdoc ICentuari
    function repay(
        address borrower,
        address loanToken,
        uint256 maturity,
        uint256 amount
    ) external onlyOperator whenNotPaused nonReentrant {
        if (borrower == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();

        bytes32 marketId = _getMarketId(loanToken, maturity);
        uint256 debt = _borrowDebt[marketId][borrower];

        if (debt == 0) revert InvalidAmount();

        uint256 repayAmount = amount > debt ? debt : amount;
        if (repayAmount == 0) revert InvalidAmount();

        _borrowDebt[marketId][borrower] = debt - repayAmount;

        ITreasury(_treasury).repay(borrower, loanToken, repayAmount);

        emit Repaid(marketId, borrower, repayAmount);
    }

    /// @inheritdoc ICentuari
    function withdrawLendPosition(
        address loanToken,
        uint256 maturity,
        uint256 cbtAmount
    ) external whenNotPaused nonReentrant {
        if (cbtAmount == 0) revert InvalidAmount();
        if (_bondTokenFactory == address(0)) revert BondTokenNotFound();

        address bondToken = CentuariBondERC20Factory(_bondTokenFactory).getBondToken(loanToken, maturity);
        if (bondToken == address(0)) revert BondTokenNotFound();

        if (block.timestamp < maturity) revert NotYetMatured();

        bytes32 marketId = _getMarketId(loanToken, maturity);

        if (_lendPositionCbtAmount[marketId][msg.sender] < cbtAmount) revert InvalidAmount();
        if (_marketTotalCbt[marketId] < cbtAmount) revert InvalidAmount();

        CentuariBondERC20(bondToken).burnFrom(msg.sender, cbtAmount);

        _lendPositionCbtAmount[marketId][msg.sender] -= cbtAmount;
        _marketTotalCbt[marketId] -= cbtAmount;

        ITreasury(_treasury).withdrawLendPosition(msg.sender, loanToken, cbtAmount);

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
        interest = (principal * rate * days_) / (RATE_PRECISION * 365);
    }

    /// @notice Calculate market ID from loan token and maturity
    /// @param loanToken The loan token address
    /// @param maturity The maturity timestamp
    /// @return The market ID
    function _getMarketId(address loanToken, uint256 maturity) internal pure returns (bytes32) {
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

    /// @notice Update the Treasury contract address
    /// @dev Only callable by owner
    /// @param newTreasury The new Treasury contract address
    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();

        address oldTreasury = _treasury;
        _treasury = newTreasury;

        emit TreasuryUpdated(oldTreasury, newTreasury);
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
    function getMarketId(address loanToken, uint256 maturity) external pure returns (bytes32) {
        return _getMarketId(loanToken, maturity);
    }

    /// @inheritdoc ICentuari
    function getMarketTotalCbt(bytes32 marketId) external view returns (uint256) {
        return _marketTotalCbt[marketId];
    }

    /// @inheritdoc ICentuari
    function getLendPositionCbtAmount(bytes32 marketId, address lender) external view returns (uint256) {
        return _lendPositionCbtAmount[marketId][lender];
    }

    /// @inheritdoc ICentuari
    function getBorrowPosition(bytes32 marketId, address borrower) external view returns (uint256) {
        return _borrowDebt[marketId][borrower];
    }

    /// @inheritdoc ICentuari
    function settlement() external view returns (address) {
        return _settlement;
    }

    /// @inheritdoc ICentuari
    function treasury() external view returns (address) {
        return _treasury;
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
