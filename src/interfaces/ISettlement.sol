// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ISettlement
/// @notice Interface for the Settlement contract that processes batch settlements from the matching engine
/// @dev Settlement validates matches, prevents double-settlement, and calls Centuari for position updates
interface ISettlement {
    // ============ Structs ============

    /// @notice Data structure representing a matched order from the matching engine
    /// @param matchId Unique match identifier provided by the settlement engine
    /// @param lendOrderId The unique identifier of the lend order
    /// @param borrowOrderId The unique identifier of the borrow order
    /// @param lender The address of the lender
    /// @param borrower The address of the borrower
    /// @param matchedAmount The matched principal amount in loanToken units
    /// @param rate Interest rate in basis points (e.g., 500 = 5%)
    /// @param loanToken The address of the loan token
    /// @param maturity Unix timestamp when the loan matures
    /// @param timestamp Unix timestamp when the match was created by the matching engine
    /// @param borrowerIsTaker True if the borrower was the taker in this match
    /// @param lenderSettlementFee Settlement fee charged to the lender
    /// @param borrowerSettlementFee Settlement fee charged to the borrower
    /// @param makerFeeAmount Trade fee charged to the maker
    /// @param takerFeeAmount Trade fee charged to the taker
    /// @param collateralAssets Borrower's explicit, unfulfilled flag-as-collateral requests to fulfill
    ///        at this settlement. Empty array means no flag changes. Idempotent in BalanceLedger:
    ///        re-submitting an already-flagged asset is a no-op and does not refresh `_flaggedAt`.
    struct MatchData {
        bytes32 matchId;
        bytes32 marketId;
        bytes32 lendOrderId;
        bytes32 borrowOrderId;
        address lender;
        address borrower;
        uint256 matchedAmount;
        uint256 rate;
        address loanToken;
        uint256 maturity;
        uint256 timestamp;
        bool borrowerIsTaker;
        uint256 lenderSettlementFee;
        uint256 borrowerSettlementFee;
        uint256 makerFeeAmount;
        uint256 takerFeeAmount;
        address[] collateralAssets;
    }

    // ============ Events ============

    /// @notice Emitted when a single match is settled
    /// @param matchId The unique identifier of the settled match
    /// @param lendOrderId The lend order ID
    /// @param borrowOrderId The borrow order ID
    /// @param lender The lender address
    /// @param borrower The borrower address
    /// @param loanToken The loan token address
    /// @param matchedAmount The matched principal amount
    /// @param rate The interest rate in basis points
    /// @param maturity The maturity timestamp
    /// @param lenderSettlementFee Settlement fee charged to the lender (pre-split off-chain)
    /// @param borrowerSettlementFee Settlement fee charged to the borrower (pre-split off-chain)
    event MatchSettled(
        bytes32 indexed matchId,
        bytes32 indexed lendOrderId,
        bytes32 indexed borrowOrderId,
        address lender,
        address borrower,
        address loanToken,
        uint256 matchedAmount,
        uint256 rate,
        uint256 maturity,
        uint256 lenderSettlementFee,
        uint256 borrowerSettlementFee
    );

    /// @notice Emitted when a batch settlement is completed
    /// @param matchCount The number of matches settled in the batch
    /// @param totalVolume The total volume settled
    event BatchSettlementCompleted(uint256 matchCount, uint256 totalVolume);

    /// @notice Emitted when the operator address is updated
    /// @param oldOperator The previous operator address
    /// @param newOperator The new operator address
    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);

    /// @notice Emitted when the Centuari contract address is updated
    /// @param oldCentuari The previous Centuari address
    /// @param newCentuari The new Centuari address
    event CentuariUpdated(address indexed oldCentuari, address indexed newCentuari);

    /// @notice Emitted when the contract is paused
    /// @param account The account that paused the contract
    event Paused(address account);

    /// @notice Emitted when the contract is unpaused
    /// @param account The account that unpaused the contract
    event Unpaused(address account);

    // ============ Errors ============

    /// @notice Thrown when caller is not authorized
    error Unauthorized();

    /// @notice Thrown when attempting to settle an already settled match
    /// @param matchId The ID of the already settled match
    error AlreadySettled(bytes32 matchId);

    /// @notice Thrown when match data is invalid
    error InvalidMatchData();

    /// @notice Thrown when a zero address is provided
    error ZeroAddress();

    /// @notice Thrown when the contract is paused
    error ContractPaused();

    /// @notice Thrown when an empty batch is provided
    error EmptyBatch();

    // ============ Core Settlement Functions ============

    /// @notice Settle multiple matches in a batch
    /// @dev Only callable by the operator. Iterates through matches and calls Centuari for each.
    /// @param matches Array of match data to settle
    function settleMatches(MatchData[] calldata matches) external;

    /// @notice Settle a single match
    /// @dev Convenience wrapper for single settlements. Only callable by the operator.
    /// @param matchData The match data to settle
    function settleMatch(MatchData calldata matchData) external;

    // ============ View Functions ============

    /// @notice Check if a match has already been settled
    /// @param matchId The match ID to check
    /// @return True if the match has been settled
    function isSettled(bytes32 matchId) external view returns (bool);

    /// @notice Get the current operator address
    /// @return The operator address
    function operator() external view returns (address);

    /// @notice Get the Centuari contract address
    /// @return The Centuari contract address
    function centuari() external view returns (address);
}
