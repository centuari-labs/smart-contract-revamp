// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "../utils/ReentrancyGuardUpgradeable.sol";

import {ICentuari} from "../interfaces/ICentuari.sol";
import {ITreasury} from "../interfaces/ITreasury.sol";
import {CentuariStorage} from "./CentuariStorage.sol";

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

    // ============ Core Settlement Function ============

    /// @inheritdoc ICentuari
    function settleMatch(
        bytes32, // matchId - unused, for future use
        address lender,
        bytes32, // lendOrderId - unused, for future use
        address borrower,
        bytes32, // borrowOrderId - unused, for future use
        address loanToken,
        uint256 matchedAmount,
        uint256 rate,
        uint256 maturity
    ) external onlySettlement whenNotPaused nonReentrant {
        // Validate inputs
        if (matchedAmount == 0) revert InvalidAmount();
        if (maturity <= block.timestamp) revert InvalidMaturity();

        // Calculate market ID and get market storage
        bytes32 marketId = _getMarketId(loanToken, maturity);
        Market storage market = _markets[marketId];

        // Emit MarketCreated if this is a new market
        if (market.totalLendShares == 0 && market.totalBorrowShares == 0) {
            emit MarketCreated(marketId, loanToken, maturity);
        }

        // Process lender position
        _processLendPosition(marketId, lender, matchedAmount, rate);

        // Process borrower position (calculate debt inline)
        _processBorrowPosition(
            marketId,
            borrower,
            matchedAmount,
            matchedAmount + _calculateInterest(matchedAmount, rate, maturity),
            rate
        );

        // Call Treasury to execute the token transfer
        // TODO: Calculate and pass fee (currently 0)
        ITreasury(_treasury).settle(loanToken, lender, borrower, matchedAmount, 0);

        // TODO: Mint bond tokens to lender
        // This will be implemented later when bond token contract is ready
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
    /// @param debt The total debt (principal + interest)
    /// @param rate The interest rate in basis points
    /// @return shares The debt shares assigned to the borrower
    function _processBorrowPosition(
        bytes32 marketId,
        address borrower,
        uint256 principal,
        uint256 debt,
        uint256 rate
    ) internal returns (uint256 shares) {
        Market storage market = _markets[marketId];

        // Calculate shares using debt-to-shares conversion
        // For first borrow, shares = debt (1:1)
        if (market.totalBorrowShares == 0) {
            shares = debt;
        } else {
            shares = (debt * market.totalBorrowShares) / market.totalBorrowAssets;
        }

        // Update market totals
        market.totalBorrowShares += shares;
        market.totalBorrowAssets += debt;

        // Update borrower's position
        BorrowPosition storage position = _borrowPositions[marketId][borrower];
        position.shares += shares;
        position.principalBorrowed += principal;

        emit BorrowPositionCreated(marketId, borrower, shares, principal, debt, rate);
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
    function getBorrowPosition(bytes32 marketId, address borrower) external view returns (BorrowPosition memory) {
        return _borrowPositions[marketId][borrower];
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
}
