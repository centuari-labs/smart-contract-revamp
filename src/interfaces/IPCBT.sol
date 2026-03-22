// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IPCBT
/// @notice Interface for Perpetual CBT Vault — wraps CBT into a perpetual composable ERC-20
/// @dev One vault per stablecoin denomination (pCBT-USDC, pCBT-IDRX, pCBT-XSGD).
///      Users deposit CBT, receive pCBT. Vault auto-rolls at maturity.
interface IPCBT {
    // ============ Structs ============

    struct WithdrawalRequest {
        address user;
        uint256 shares;
        uint256 requestedAt;
    }

    struct EarlyExitRequest {
        uint256 shares;
        uint8 orderType;
        uint256 minPrice;
        bool active;
    }

    // ============ Core Functions ============

    /// @notice Deposit CBT tokens into the vault, receive pCBT shares
    /// @param cbtAmount The amount of CBT to deposit
    /// @return pCBTMinted The amount of pCBT shares minted
    function depositCBT(uint256 cbtAmount) external returns (uint256 pCBTMinted);

    /// @notice Request withdrawal from vault — processed at next maturity (FIFO queue)
    /// @param shares The amount of pCBT shares to withdraw
    function requestWithdrawal(uint256 shares) external;

    /// @notice Cancel a pending withdrawal request
    function cancelWithdrawal() external;

    /// @notice Request early exit by selling CBT on the CLOB via CentuariRouter
    /// @param shares The amount of pCBT shares to exit
    /// @param orderType 0 = MARKET, 1 = LIMIT
    /// @param minPrice Minimum price per CBT (0 for market orders)
    function requestEarlyExit(uint256 shares, uint8 orderType, uint256 minPrice) external;

    /// @notice Cancel a pending early exit request
    function cancelEarlyExit() external;

    // ============ Settlement (Endpoint Only) ============

    /// @notice Called by CentuariEndpoint after maturity rollover settlement
    /// @param newCBT The new CBT contract address for the next maturity
    /// @param newCBTAmount The amount of new CBT minted to vault
    /// @param redeemedUSDC The USDC redeemed from matured CBT (for withdrawal payouts)
    function onSettlement(address newCBT, uint256 newCBTAmount, uint256 redeemedUSDC) external;

    // ============ View Functions ============

    /// @notice Current share price: (total CBT fair value + idle USDC) / totalSupply
    /// @return price Share price with 18 decimals
    function sharePrice() external view returns (uint256 price);

    /// @notice Address of the current active CBT contract held by vault
    function currentCBTAddress() external view returns (address);

    /// @notice Collateral value per pCBT share for RiskModule/CollateralRegistry pricing
    /// @return valueUSD USD value per share with 18 decimals
    function collateralValuePerPCBT() external view returns (uint256 valueUSD);

    /// @notice Total assets breakdown
    /// @return cbtHeld Amount of CBT tokens held
    /// @return cbtFairValueUSD Fair value of held CBT in USD (18 decimals)
    /// @return idleUSDC Amount of idle USDC not yet deployed to CBT
    function totalAssets() external view returns (uint256 cbtHeld, uint256 cbtFairValueUSD, uint256 idleUSDC);

    /// @notice The underlying loan token (USDC, IDRX, etc.)
    function loanToken() external view returns (address);

    /// @notice Get the withdrawal queue length
    function withdrawalQueueLength() external view returns (uint256);

    /// @notice Get a withdrawal request by index
    function getWithdrawalRequest(uint256 index) external view returns (WithdrawalRequest memory);

    // ============ Events ============

    event CBTDeposited(address indexed user, uint256 cbtAmount, uint256 pCBTMinted);
    event WithdrawalRequested(address indexed user, uint256 shares);
    event WithdrawalCancelled(address indexed user, uint256 shares);
    event EarlyExitRequested(address indexed user, uint256 shares, uint8 orderType, uint256 minPrice);
    event EarlyExitCancelled(address indexed user);
    event MaturityProcessed(address indexed oldCBT, address indexed newCBT, uint256 newCBTAmount, uint256 withdrawalsPaid);
    event WithdrawalFulfilled(address indexed user, uint256 shares, uint256 usdcAmount);

    // ============ Errors ============

    error ZeroAmount();
    error ZeroAddress();
    error InsufficientShares();
    error WithdrawalCutoffPassed();
    error NoWithdrawalPending();
    error NoEarlyExitPending();
    error EarlyExitAlreadyPending();
    error WithdrawalAlreadyPending();
    error OnlyEndpoint();
}
