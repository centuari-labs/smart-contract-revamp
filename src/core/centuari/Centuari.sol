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

        // Calculate market ID and get market storage
        bytes32 marketId = _getMarketId(loanToken, maturity);
        Market storage market = _markets[marketId];

        // Emit MarketCreated if this is a new market
        if (market.totalLendShares == 0) {
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


        //@todo : use CBT concept (ZCB)
        // Process lender position (with full matchedAmount for proper market accounting)
        uint256 shares = _processLendPosition(marketId, lender, matchedAmount, rate);

        // Process borrower position
        _processBorrowPosition(marketId, borrower, matchedAmount, rate, maturity);

        // Calculate net amounts after fees
        // Convert lenderFee from token amount to shares using the same ratio as position calculation
        uint256 feeShares;
        if (lenderFee > 0 && shares > 0) {
            // Use the same ratio: feeShares / lenderFee = shares / matchedAmount
            feeShares = (lenderFee * shares) / matchedAmount;
        }
        
        // Calculate net loan amount for borrower (matchedAmount - borrowerFee)
        uint256 netLoanAmountForBorrower = matchedAmount - borrowerFee;

        // Call Treasury to execute the token transfer with pre-split settlement fees
        // Transfer net loan amount (after borrower fee deduction) to borrower
        ITreasury(_treasury).settle(
            loanToken,
            lender,
            borrower,
            netLoanAmountForBorrower,
            lenderSettlementFee,
            borrowerSettlementFee
        );

        // Mint bond tokens to lender (if factory is set)
        // Mint shares minus feeShares to account for lender fee
        if (_bondTokenFactory != address(0)) {
            address bondToken = CentuariBondERC20Factory(_bondTokenFactory).getOrCreate(
                loanToken,
                maturity
            );
            // Ensure we don't mint negative or zero shares
            if (shares > feeShares) {
                CentuariBondERC20(bondToken).mint(lender, shares - feeShares);
            }
        }
    }

    // ============ Internal Functions ============

    /// @notice Process the lender's position
    /// @param marketId The market identifier
    /// @param lender The lender address
    /// @param principal The principal amount being lent
    /// @param rate The interest rate in basis points
    /// @return shares The shares issued to the lender
    function _processLendPosition(
        bytes32 marketId,
        address lender,
        uint256 principal,
        uint256 rate
    ) internal returns (uint256 shares) {
        Market storage market = _markets[marketId];
        //@todo : use ZCB
        //@todo : need to calculate the yield from the maturity
        // Calculate shares using assets-to-shares conversion
        // For first deposit, shares = assets (1:1)
        if (market.totalLendShares == 0) {
            shares = principal;
        } else {
            shares = (principal * market.totalLendShares) / market.totalLendAssets;
        }

        // Update market totals
        market.totalLendShares += shares;
        market.totalLendAssets += principal;

        // Update lender's position
        LendPosition storage position = _lendPositions[marketId][lender];
        position.shares += shares;
        position.principalLent += principal;

        emit LendPositionCreated(marketId, lender, shares, principal, rate);
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
        uint256 debt = principal + _calculateInterest(principal, rate, maturity);
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

        bytes32 marketId = _getMarketId(loanToken, maturity);
        Market storage market = _markets[marketId];
        LendPosition storage position = _lendPositions[marketId][msg.sender];

        if (position.shares < cbtAmount) revert InvalidAmount();
        if (market.totalLendShares == 0) revert InvalidAmount();

        uint256 assetsOut = (cbtAmount * market.totalLendAssets) / market.totalLendShares;

        CentuariBondERC20(bondToken).burnFrom(msg.sender, cbtAmount);

        position.shares -= cbtAmount;
        position.principalLent -= assetsOut;

        market.totalLendShares -= cbtAmount;
        market.totalLendAssets -= assetsOut;

        ITreasury(_treasury).withdrawLendPosition(msg.sender, loanToken, assetsOut);

        emit LendPositionWithdrawn(marketId, msg.sender, cbtAmount, assetsOut);
    }

    /// @notice Calculate interest for a loan
    /// @param principal The principal amount
    /// @param rate The interest rate in basis points (e.g., 500 = 5%)
    /// @param maturity The maturity timestamp
    /// @return interest The calculated interest amount
    function _calculateInterest(
        uint256 principal,
        uint256 rate,
        uint256 maturity
    ) internal view returns (uint256 interest) {
        // Duration from now until maturity
        uint256 duration = maturity - block.timestamp;

        // Simple interest calculation: principal * rate * duration / (RATE_PRECISION * SECONDS_PER_YEAR)
        // Rate is in basis points, so 500 = 5% = 0.05
        interest = (principal * rate * duration) / (RATE_PRECISION * SECONDS_PER_YEAR);
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
    function getMarket(bytes32 marketId) external view returns (Market memory) {
        return _markets[marketId];
    }

    /// @inheritdoc ICentuari
    function getLendPosition(bytes32 marketId, address lender) external view returns (LendPosition memory) {
        return _lendPositions[marketId][lender];
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
