// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ICentuari
/// @notice Interface for the Centuari contract that manages lending positions
/// @dev Settlement calls this interface to settle matched orders.
///      Centuari handles positions (bond tokens, debt) and calls Treasury.settle()
interface ICentuari {
    // ============ Structs ============

    /// @notice Market state for a (loanToken, maturity) pair
    /// @param totalLendShares Total lend shares issued in this market
    /// @param totalLendAssets Total principal lent (used for share calculation)
    /// @param totalBorrowShares Total borrow shares issued in this market
    /// @param totalBorrowAssets Total debt (principal + interest) in this market
    struct Market {
        uint256 totalLendShares;
        uint256 totalLendAssets;
        uint256 totalBorrowShares;
        uint256 totalBorrowAssets;
    }

    /// @notice Lend position for a user in a specific market
    /// @param shares User's lend shares in the market
    /// @param principalLent Original principal amount lent (for reference)
    struct LendPosition {
        uint256 shares;
        uint256 principalLent;
    }

    /// @notice Borrow position for a user in a specific market
    /// @param shares User's borrow/debt shares in the market
    /// @param principalBorrowed Original principal amount borrowed (for reference)
    struct BorrowPosition {
        uint256 shares;
        uint256 principalBorrowed;
    }

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
    /// @param shares The shares added to the position
    /// @param principal The principal amount lent
    /// @param rate The interest rate in basis points
    event LendPositionCreated(
        bytes32 indexed marketId,
        address indexed lender,
        uint256 shares,
        uint256 principal,
        uint256 rate
    );

    /// @notice Emitted when a borrow position is created or updated
    /// @param marketId The market identifier
    /// @param borrower The borrower address
    /// @param shares The shares added to the position
    /// @param principal The principal amount borrowed
    /// @param debt The total debt (principal + interest)
    /// @param rate The interest rate in basis points
    event BorrowPositionCreated(
        bytes32 indexed marketId,
        address indexed borrower,
        uint256 shares,
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

    /// @notice Emitted when the contract is paused
    /// @param account The account that paused the contract
    event Paused(address account);

    /// @notice Emitted when the contract is unpaused
    /// @param account The account that unpaused the contract
    event Unpaused(address account);

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

    // ============ Core Functions ============

    /// @notice Settle a matched order - handles positions, token transfers, and fees atomically
    /// @dev This function should:
    ///      1. Record lend position and mint bond tokens to lender (TODO: bond tokens later)
    ///      2. Record borrow position (debt) for borrower
    ///      3. Call Treasury.settle() to transfer tokens to borrower and fees to FeeVault
    /// @param matchId The unique match identifier
    /// @param lender The lender address
    /// @param lendOrderId The lend order ID
    /// @param borrower The borrower address
    /// @param borrowOrderId The borrow order ID
    /// @param loanToken The loan token address
    /// @param matchedAmount The matched principal amount
    /// @param rate The interest rate in basis points
    /// @param maturity The maturity timestamp
    function settleMatch(
        bytes32 matchId,
        address lender,
        bytes32 lendOrderId,
        address borrower,
        bytes32 borrowOrderId,
        address loanToken,
        uint256 matchedAmount,
        uint256 rate,
        uint256 maturity
    ) external;

    // ============ View Functions ============

    /// @notice Get the market ID for a given loan token and maturity
    /// @param loanToken The loan token address
    /// @param maturity The maturity timestamp
    /// @return The market ID (keccak256 hash)
    function getMarketId(address loanToken, uint256 maturity) external pure returns (bytes32);

    /// @notice Get the market state for a given market ID
    /// @param marketId The market identifier
    /// @return The market state struct
    function getMarket(bytes32 marketId) external view returns (Market memory);

    /// @notice Get the lend position for a user in a specific market
    /// @param marketId The market identifier
    /// @param lender The lender address
    /// @return The lend position struct
    function getLendPosition(bytes32 marketId, address lender) external view returns (LendPosition memory);

    /// @notice Get the borrow position for a user in a specific market
    /// @param marketId The market identifier
    /// @param borrower The borrower address
    /// @return The borrow position struct
    function getBorrowPosition(bytes32 marketId, address borrower) external view returns (BorrowPosition memory);

    /// @notice Get the Settlement contract address
    /// @return The Settlement contract address
    function settlement() external view returns (address);

    /// @notice Get the Treasury contract address
    /// @return The Treasury contract address
    function treasury() external view returns (address);

    /// @notice Check if the contract is paused
    /// @return True if the contract is paused
    function paused() external view returns (bool);
}
