// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ICentuari
/// @notice Interface for the Centuari contract that manages lending positions
/// @dev Settlement calls this interface to settle matched orders.
///      Centuari handles positions (bond tokens, debt) and calls Treasury.settle()
interface ICentuari {
    // ============ Events ============

    /// @notice Emitted when a new market is created
    /// @param marketId The unique market identifier
    /// @param loanToken The loan token address
    /// @param maturity The maturity timestamp
    event MarketCreated(
        bytes32 indexed marketId,
        address indexed loanToken,
        uint256 indexed maturity
    );

    /// @notice Emitted when a lend position is created or updated
    /// @param marketId The market identifier
    /// @param lender The lender address
    /// @param cbtAmount The CBT (claim at maturity) added to the position
    /// @param principal The effective principal amount lent (after fees)
    /// @param rate The interest rate in basis points
    event LendPositionCreated(
        bytes32 indexed marketId,
        address indexed lender,
        uint256 cbtAmount,
        uint256 principal,
        uint256 rate
    );

    /// @notice Emitted when a borrow position is created or updated
    /// @param marketId The market identifier
    /// @param borrower The borrower address
    /// @param principal The principal amount borrowed
    /// @param debt The total debt (principal + interest)
    /// @param rate The interest rate in basis points
    event BorrowPositionCreated(
        bytes32 indexed marketId,
        address indexed borrower,
        uint256 principal,
        uint256 debt,
        uint256 rate
    );

    /// @notice Emitted when the Settlement contract address is updated
    /// @param oldSettlement The previous Settlement address
    /// @param newSettlement The new Settlement address
    event SettlementUpdated(address indexed oldSettlement, address indexed newSettlement);

    /// @notice Emitted when the Treasury contract address is updated
    /// @param oldTreasury The previous Treasury address
    /// @param newTreasury The new Treasury address
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    /// @notice Emitted when the Bond Token Factory contract address is updated
    /// @param oldFactory The previous factory address
    /// @param newFactory The new factory address
    event BondTokenFactoryUpdated(address indexed oldFactory, address indexed newFactory);

    /// @notice Emitted when the contract is paused
    /// @param account The account that paused the contract
    event Paused(address account);

    /// @notice Emitted when the contract is unpaused
    /// @param account The account that unpaused the contract
    event Unpaused(address account);

    /// @notice Emitted when a borrow position is repaid
    /// @param marketId The market identifier
    /// @param borrower The borrower address
    /// @param amount The amount repaid (in token terms)
    event Repaid(
        bytes32 indexed marketId,
        address indexed borrower,
        uint256 amount
    );

    /// @notice Emitted when the operator address is updated
    /// @param oldOperator The previous operator address
    /// @param newOperator The new operator address
    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);

    /// @notice Emitted when a lender withdraws (redeems) part or all of their lend position
    /// @param marketId The market identifier
    /// @param lender The lender address
    /// @param cbtBurned The CBT (bond token) amount burned
    /// @param amountWithdrawn The loan token amount credited to the lender (1:1 with cbtBurned)
    event LendPositionWithdrawn(
        bytes32 indexed marketId,
        address indexed lender,
        uint256 cbtBurned,
        uint256 amountWithdrawn
    );

    // ============ Errors ============

    /// @notice Thrown when caller is not authorized
    error Unauthorized();

    /// @notice Thrown when a zero address is provided
    error ZeroAddress();

    /// @notice Thrown when an invalid amount is provided
    error InvalidAmount();

    /// @notice Thrown when the contract is paused
    error ContractPaused();

    /// @notice Thrown when maturity is in the past
    error InvalidMaturity();

    /// @notice Thrown when bond token does not exist for the market (factory not set or market not settled)
    error BondTokenNotFound();

    // ============ Core Functions ============

    /// @notice Settle a matched order - handles positions, token transfers, and fees atomically
    /// @dev This function should:
    ///      1. Record lend position and mint bond tokens to lender
    ///      2. Record borrow position (debt) for borrower
    ///      3. Call Treasury.settle() to transfer tokens to borrower and settlement fees to Treasury
    /// @param lender The lender address
    /// @param borrower The borrower address
    /// @param loanToken The loan token address
    /// @param matchedAmount The matched principal amount
    /// @param rate The interest rate in basis points
    /// @param maturity The maturity timestamp
    /// @param borrowerIsTaker True if the borrower was the taker in this match
    /// @param lenderSettlementFee Settlement fee charged to the lender (pre-split off-chain)
    /// @param borrowerSettlementFee Settlement fee charged to the borrower (pre-split off-chain)
    /// @param makerFeeAmount Trade fee charged to the maker (for Centuari internal accounting)
    /// @param takerFeeAmount Trade fee charged to the taker (for Centuari internal accounting)
    function settleMatch(
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
        uint256 takerFeeAmount
    ) external;

    /// @notice Repay debt for a borrower in a given market. Only callable by operator (backend).
    /// @param borrower The borrower address
    /// @param loanToken The loan token address
    /// @param maturity The maturity timestamp (identifies the market)
    /// @param amount The amount to repay (capped to current debt)
    function repay(
        address borrower,
        address loanToken,
        uint256 maturity,
        uint256 amount
    ) external;

    /// @notice Redeem CBT (bond tokens) for loan tokens. Burns CBT from caller and credits loan tokens to caller's Treasury balance.
    /// @dev Caller must have approved Centuari to spend at least cbtAmount of the market's bond token.
    ///      Withdrawable amount is limited by Treasury's available balance (from repayments).
    /// @param loanToken The loan token address
    /// @param maturity The maturity timestamp (identifies the market)
    /// @param cbtAmount The amount of CBT (bond token) to redeem
    function withdrawLendPosition(
        address loanToken,
        uint256 maturity,
        uint256 cbtAmount
    ) external;

    // ============ View Functions ============

    /// @notice Get the market ID for a given loan token and maturity
    /// @param loanToken The loan token address
    /// @param maturity The maturity timestamp
    /// @return The market ID (keccak256 hash)
    function getMarketId(address loanToken, uint256 maturity) external pure returns (bytes32);

    /// @notice Get total CBT minted for a market
    /// @param marketId The market identifier
    /// @return totalCbt Total CBT (claim at maturity) minted in this market
    function getMarketTotalCbt(bytes32 marketId) external view returns (uint256 totalCbt);

    /// @notice Get a lender's CBT amount in a specific market
    /// @param marketId The market identifier
    /// @param lender The lender address
    /// @return cbtAmount The lender's claim at maturity (CBT) in this market
    function getLendPositionCbtAmount(bytes32 marketId, address lender) external view returns (uint256 cbtAmount);

    /// @notice Get the borrow debt for a user in a specific market
    /// @param marketId The market identifier
    /// @param borrower The borrower address
    /// @return The total debt (principal + interest) for this position
    function getBorrowPosition(bytes32 marketId, address borrower) external view returns (uint256);

    /// @notice Get the Settlement contract address
    /// @return The Settlement contract address
    function settlement() external view returns (address);

    /// @notice Get the Treasury contract address
    /// @return The Treasury contract address
    function treasury() external view returns (address);

    /// @notice Check if the contract is paused
    /// @return True if the contract is paused
    function paused() external view returns (bool);

    /// @notice Get the Bond Token Factory contract address
    /// @return The Bond Token Factory contract address
    function bondTokenFactory() external view returns (address);

    /// @notice Get the operator (backend) address
    /// @return The operator address
    function operator() external view returns (address);

    /// @notice Set the operator address. Only owner.
    /// @param newOperator The new operator address
    function setOperator(address newOperator) external;
}
