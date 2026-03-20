// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ITreasury
/// @notice Interface for the Treasury contract that handles token transfers
/// @dev Treasury manages deposits, withdrawals, and settlement transfers.
///      Centuari calls this interface to execute token transfers during settlement.
interface ITreasury {
    // ============ Events ============

    /// @notice Emitted when a settlement transfer is executed
    /// @param loanToken The loan token address
    /// @param from The address funds are transferred from (lender's deposit)
    /// @param to The address funds are transferred to (borrower)
    /// @param amount The principal amount transferred
    /// @param lenderSettlementFee The settlement fee amount charged to the lender
    /// @param borrowerSettlementFee The settlement fee amount charged to the borrower
    /// @param lenderTradeFee The maker/taker trade fee charged to the lender
    /// @param borrowerTradeFee The maker/taker trade fee charged to the borrower
    event SettlementExecuted(
        address indexed loanToken,
        address indexed from,
        address indexed to,
        uint256 amount,
        uint256 lenderSettlementFee,
        uint256 borrowerSettlementFee,
        uint256 lenderTradeFee,
        uint256 borrowerTradeFee
    );

    /// @notice Emitted when protocol fees are withdrawn by admin
    /// @param token The token address
    /// @param recipient The recipient address
    /// @param amount The amount withdrawn
    event ProtocolFeesWithdrawn(
        address indexed token,
        address indexed recipient,
        uint256 amount
    );

    /// @notice Emitted when token support is updated
    /// @param token The token address
    /// @param supported Whether the token is now supported
    event TokenSupportUpdated(address indexed token, bool supported);

    /// @notice Emitted when Centuari contract address is updated
    /// @param centuariContract The new Centuari contract address
    event CentuariContractUpdated(address indexed centuariContract);

    /// @notice Emitted when a user deposits tokens
    /// @param user The user address
    /// @param token The token address
    /// @param amount The amount deposited
    event Deposited(
        address indexed user,
        address indexed token,
        uint256 amount
    );

    event OperatorUpdated(
        address indexed oldOperator,
        address indexed newOperator
    );

    /// @notice Emitted when a user withdraws tokens
    /// @param user The user address
    /// @param token The token address
    /// @param amount The amount withdrawn
    event Withdrawn(
        address indexed user,
        address indexed token,
        uint256 amount
    );

    /// @notice Emitted when a user repays a loan
    /// @param user The user address
    /// @param token The token address
    /// @param amount The amount repaid
    event Repay(address indexed user, address indexed token, uint256 amount);

    /// @notice Emitted when a lender withdraws their position
    /// @param user The user address
    /// @param token The token address
    /// @param amount The amount withdrawn
    event WithdrawLendPosition(
        address indexed user,
        address indexed token,
        uint256 amount
    );

    /// @notice Emitted for internal transfers
    /// @param from The source address
    /// @param to The destination address
    /// @param token The token address
    /// @param amount The amount transferred
    /// @param ref The reference identifier
    event InternalTransfer(
        address indexed from,
        address indexed to,
        address indexed token,
        uint256 amount,
        bytes32 ref
    );

    // ============ Errors ============

    /// @notice Thrown when caller is not authorized
    error Unauthorized();

    /// @notice Thrown when a zero address is provided
    error ZeroAddress();

    /// @notice Thrown when an invalid amount is provided
    error InvalidAmount();

    /// @notice Thrown when there are insufficient funds
    error InsufficientFunds();

    // ============ Core Functions ============

    /// @notice Execute a settlement transfer
    /// @dev Called by Centuari during match settlement.
    ///      Transfers full principal from lender to borrower. All fees (settlement + trade)
    ///      are deducted from each party's treasury balance and collected as protocol revenue.
    /// @param loanToken The loan token address
    /// @param from The lender address (funds come from their deposit)
    /// @param to The borrower address (receives the loan)
    /// @param amount The full principal amount to transfer (no fee deduction)
    /// @param lenderSettlementFee The settlement fee amount charged to the lender
    /// @param borrowerSettlementFee The settlement fee amount charged to the borrower
    /// @param lenderTradeFee The maker/taker trade fee charged to the lender
    /// @param borrowerTradeFee The maker/taker trade fee charged to the borrower
    function settle(
        address loanToken,
        address from,
        address to,
        uint256 amount,
        uint256 lenderSettlementFee,
        uint256 borrowerSettlementFee,
        uint256 lenderTradeFee,
        uint256 borrowerTradeFee
    ) external;

    /// @notice Get accumulated protocol fee balance for a token
    /// @param token The token address
    /// @return The accumulated protocol fee balance
    function protocolFeeBalance(address token) external view returns (uint256);

    /// @notice Withdraw accumulated protocol fees
    /// @param token The token address
    /// @param recipient The recipient address
    /// @param amount The amount to withdraw
    function withdrawProtocolFees(
        address token,
        address recipient,
        uint256 amount
    ) external;

    /// @notice Set token support status
    /// @param token The token address
    /// @param supported Whether the token should be supported
    function setSupportedToken(address token, bool supported) external;

    /// @notice Set Centuari contract address
    /// @param _centuariContract The new Centuari contract address
    function setCentuariContract(address _centuariContract) external;

    /// @notice Register a bond token so it can be used in Treasury operations
    /// @param bondToken The CBT bond token address
    function registerBondToken(address bondToken) external;

    /// @notice Deposit tokens to treasury
    /// @param token The token address
    /// @param amount The amount to deposit
    function deposit(address token, uint256 amount) external;

    /// @notice Withdraw tokens from treasury
    /// @param token The token address
    /// @param to The recipient address
    /// @param amount The amount to withdraw
    function withdraw(address token, address to, uint256 amount) external;

    /// @notice Repay loan position
    /// @param user The user address
    /// @param token The token address
    /// @param amount The amount to repay
    function repay(address user, address token, uint256 amount) external;

    /// @notice Withdraw lender position
    /// @param user The user address
    /// @param token The token address
    /// @param amount The amount to withdraw
    function withdrawLendPosition(
        address user,
        address token,
        uint256 amount
    ) external;

    /// @notice Record a newly minted bond position for a user
    /// @param user The user address
    /// @param bondToken The CBT bond token address
    /// @param amount The amount of CBT minted for the user
    function recordBondMint(
        address user,
        address bondToken,
        uint256 amount
    ) external;

    /// @notice Burn a user's bond position held in Treasury
    /// @param user The user address whose internal CBT balance is reduced
    /// @param bondToken The CBT bond token address
    /// @param amount The amount of CBT to burn
    function burnBondForUser(
        address user,
        address bondToken,
        uint256 amount
    ) external;

    /// @notice Get user balance for a token
    /// @param user The user address
    /// @param token The token address
    /// @return The user's balance for the token
    function balanceOf(
        address user,
        address token
    ) external view returns (uint256);

    /// @notice Set operator address
    function setOperator(address newOperator) external;

    /// @notice Pause contract operations
    function pause() external;

    /// @notice Unpause contract operations
    function unpause() external;

    /// @notice Get operator address
    function getOperator() external view returns (address);
}
