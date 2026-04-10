// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IHubDepositor
/// @notice Interface for the HubDepositor contract — the hub-native (Arbitrum)
///         entry point for direct deposit and withdrawal of assets.
/// @dev HubDepositor is the token custodian on the hub chain. Users on Arbitrum
///      call `deposit` to lock tokens and credit their BalanceLedger.available;
///      `payout` is called by WithdrawalRegistry (M4) when a withdrawal targets
///      Arbitrum directly (no LayerZero, no bridge). Cross-chain deposits from
///      spoke chains go through `SpokeDepositGateway` + `HubIntentSettler`
///      instead — those are separate M4/M5 contracts.
interface IHubDepositor {
    // ============ Events ============

    /// @notice Emitted when a user deposits tokens on the hub chain
    /// @param user The depositor (msg.sender)
    /// @param asset The ERC20 token deposited
    /// @param amount The amount deposited
    event Deposited(address indexed user, address indexed asset, uint256 amount);

    /// @notice Emitted when tokens are released to a user (hub-native withdrawal)
    /// @param user The recipient
    /// @param asset The ERC20 token released
    /// @param amount The amount released
    event PayoutReleased(address indexed user, address indexed asset, uint256 amount);

    // ============ Errors ============

    /// @notice Thrown when a zero address is provided where a real address is required
    error ZeroAddress();

    /// @notice Thrown when a zero amount is provided
    error ZeroAmount();

    // ============ User actions ============

    /// @notice Deposit tokens into the hub and credit BalanceLedger.available
    /// @dev Pulls tokens via safeTransferFrom then credits the BalanceLedger.
    ///      Caller must have approved this contract for at least `amount`.
    /// @param asset The ERC20 token to deposit
    /// @param amount The amount to deposit
    function deposit(address asset, uint256 amount) external;

    // ============ Authorized actions ============

    /// @notice Release tokens to a user (hub-native withdrawal payout)
    /// @dev Called by WithdrawalRegistry (M4) when the withdrawal target chain
    ///      is Arbitrum itself. Debits BalanceLedger.available then transfers
    ///      tokens to the user. Access: onlyOwner in M3 (WithdrawalRegistry
    ///      takes over in M4).
    /// @param user The recipient of the payout
    /// @param asset The ERC20 token to release
    /// @param amount The amount to release
    function payout(address user, address asset, uint256 amount) external;

    // ============ Views ============

    /// @notice The BalanceLedger this depositor writes to
    function balanceLedger() external view returns (address);
}
