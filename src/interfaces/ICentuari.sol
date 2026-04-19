// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ICentuari
/// @notice Interface for the Centuari contract that manages lending positions
/// @dev Settlement calls this interface to settle matched orders.
///      Centuari handles positions (bond tokens, debt) and calls BalanceLedger for balance mutations.
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
    /// @param bondToken The CBT (bond token) contract address for the market
    /// @param cbtAmount The CBT (claim at maturity) added to the position
    /// @param principal The effective principal amount lent (after fees)
    /// @param rate The interest rate in basis points
    event LendPositionCreated(
        bytes32 indexed marketId,
        address indexed lender,
        address indexed bondToken,
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

    /// @notice Emitted when the BalanceLedger contract address is updated
    /// @param oldLedger The previous BalanceLedger address
    /// @param newLedger The new BalanceLedger address
    event BalanceLedgerUpdated(address indexed oldLedger, address indexed newLedger);

    /// @notice Emitted when the fee collector address is updated
    /// @param oldCollector The previous fee collector address
    /// @param newCollector The new fee collector address
    event FeeCollectorUpdated(address indexed oldCollector, address indexed newCollector);

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

    /// @notice Thrown when withdrawal is attempted before maturity has passed
    error NotYetMatured();

    /// @notice Thrown when bond token does not exist for the market (factory not set or market not settled)
    error BondTokenNotFound();

    // ============ Core Functions ============

    /// @notice Settle a matched order - handles positions, balance mutations, and fees atomically
    /// @dev This function should:
    ///      1. Record lend position and mint bond tokens to Centuari (bond custodian)
    ///      2. Record borrow position (debt) for borrower, track active debt count
    ///      3. Call BalanceLedger to debit lender, credit borrower, collect protocol fees
    ///      4. Flag only the assets the borrower explicitly requested in `collateralAssets`
    ///         (empty array = no flagging). Flag/unflag is never an implicit side-effect of
    ///         settlement; it must come from an explicit user instruction propagated by the
    ///         off-chain matching/settlement engine.
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
    /// @param collateralAssets Borrower's explicit flag-as-collateral requests to fulfill at this
    ///        settlement. Idempotent via BalanceLedger; empty array means no flag mutations.
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
    ) external;

    /// @notice Repay debt for a borrower in a given market. Only callable by operator (backend).
    /// @param marketId The market identifier (bytes32)
    /// @param borrower The borrower address
    /// @param loanToken The loan token address
    /// @param amount The amount to repay (capped to current debt)
    function repay(
        bytes32 marketId,
        address borrower,
        address loanToken,
        uint256 amount
    ) external;

    /// @notice Redeem CBT (bond tokens) for loan tokens. Burns CBT from Centuari custody and credits loan tokens to caller's BalanceLedger available balance.
    /// @dev CBT is held by Centuari (bond custodian). The caller's internal _lendPositionCbtAmount tracks their claim.
    /// @param marketId The market identifier (bytes32)
    /// @param loanToken The loan token address
    /// @param maturity The maturity timestamp (used for bond token lookup and maturity check)
    /// @param cbtAmount The amount of CBT (bond token) to redeem
    function withdrawLendPosition(
        bytes32 marketId,
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

    /// @notice Get the BalanceLedger contract address
    /// @return The BalanceLedger contract address
    function balanceLedger() external view returns (address);

    /// @notice Get the number of markets where a user has non-zero debt
    /// @param user The user address
    /// @return The count of active debt markets
    function activeDebtCount(address user) external view returns (uint256);

    /// @notice Get the fee collector address
    /// @return The fee collector address
    function feeCollector() external view returns (address);

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

    /// @notice Set the BalanceLedger address. Only owner.
    /// @param newBalanceLedger The new BalanceLedger address
    function setBalanceLedger(address newBalanceLedger) external;

    /// @notice Set the fee collector address. Only owner.
    /// @param newFeeCollector The new fee collector address
    function setFeeCollector(address newFeeCollector) external;
}
