// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IPCBT
/// @notice Interface for Perpetual CBT Vault — wraps CBT into a perpetual composable ERC-20
/// @dev One vault per stablecoin denomination (pCBT-USDC, pCBT-IDRX, pCBT-XSGD).
///      Users deposit USDC (or CBT for existing lenders), receive pCBT shares.
///      Per-user rollover settings. Withdraw returns CBT directly (instant, no queue).
///      Vault auto-rolls at maturity per each user's individual settings.
interface IPCBT {
    // ============ Structs ============

    /// @notice Per-user rollover settings for auto-rollover at maturity
    struct RolloverSettings {
        bool autoRollover;         // on/off (default: ON for Easy Mode)
        uint8 ratePreference;      // 0=MARKET, 1=TARGET
        uint256 targetRateBPS;     // minimum acceptable rate (if TARGET)
        uint8 duration;            // 0=SAME (next 1st-of-month), 1=CUSTOM
        uint256 customMaturity;    // target maturity timestamp (if CUSTOM)
        uint256 maxRollovers;      // 0=unlimited, N=cap
        uint256 rolloverCount;     // incremented by engine each cycle
    }

    /// @notice Maturity processing result per user (submitted by engine)
    struct MaturityResult {
        address user;
        uint8 outcome;             // 0=ROLL, 1=RETURN
        uint256 cbtAmount;         // CBT amount for this user's portion
        uint256 usdcReturned;      // USDC to credit (RETURN outcome only)
        uint256 sharesBurned;      // pCBT shares to burn (RETURN outcome only)
        uint256 newRateBPS;        // rate for the new period (ROLL outcome only)
    }

    // ============ User Functions ============

    /// @notice Deposit USDC into vault — vault lends via engine, receives CBT
    /// @dev Path 1: New users (easy mode). USDC → vault → BalanceLedger → engine lends.
    /// @param usdcAmount Amount of underlying stablecoin to deposit
    /// @return pCBTMinted Shares minted to caller
    function deposit(uint256 usdcAmount) external returns (uint256 pCBTMinted);

    /// @notice Deposit existing CBT into vault — for users who already lent on CLOB
    /// @dev Path 2: Existing lenders joining midway. CBT must match vault's currentCBT maturity.
    /// @param cbtAmount Amount of CBT to deposit
    /// @return pCBTMinted Shares minted to caller
    function depositCBT(uint256 cbtAmount) external returns (uint256 pCBTMinted);

    /// @notice Withdraw from vault — returns proportional CBT + idle USDC instantly
    /// @dev Burns pCBT shares. No queue, no waiting. User manages CBT from there.
    /// @param shares Number of pCBT shares to burn
    /// @return cbtAmount CBT transferred to caller's wallet
    /// @return usdcAmount USDC credited to caller's BalanceLedger available
    function withdraw(uint256 shares) external returns (uint256 cbtAmount, uint256 usdcAmount);

    /// @notice Set per-user rollover settings
    /// @dev Locked 1 hour before maturity to prevent last-second gaming
    function setRolloverSettings(RolloverSettings calldata settings) external;

    // ============ Engine Functions (Endpoint Only) ============

    /// @notice Process maturity results — roll/return per user
    /// @dev Called by CentuariEndpoint during settlement batch
    function processMaturityResults(MaturityResult[] calldata results, address newCBT) external;

    // ============ View ============

    /// @notice Current share price: (totalCBTFairValue + idleUSDC) / totalSupply
    function sharePrice() external view returns (uint256 price);

    /// @notice Get a user's rollover settings
    function getUserSettings(address user) external view returns (RolloverSettings memory);

    /// @notice Next maturity date for the vault's current CBT
    function nextMaturityDate() external view returns (uint256);

    /// @notice Total vault assets
    function totalAssets() external view returns (uint256 cbtHeld, uint256 cbtFairValueUSD, uint256 idleUSDC);

    /// @notice Underlying loan token (USDC, IDRX, etc.)
    function loanToken() external view returns (address);

    // ============ Events ============

    event Deposited(address indexed user, uint256 usdcAmount, uint256 pCBTMinted);
    event CBTDeposited(address indexed user, uint256 cbtAmount, uint256 pCBTMinted);
    event Withdrawn(address indexed user, uint256 shares, uint256 cbtAmount, uint256 usdcAmount);
    event RolloverSettingsUpdated(address indexed user);
    event MaturityProcessed(address indexed oldCBT, address indexed newCBT, uint256 newCBTAmount);
    event EmergencyWindDown(uint256 cbtRedeemed, uint256 usdcRecovered);

    // ============ Errors ============

    error ZeroAddress();
    error ZeroAmount();
    error InsufficientShares();
    error WrongMaturity();
    error SettingsLocked();
    error OnlyEndpoint();
    error NoCBTSet();
    error EmergencyNotReady();
}
