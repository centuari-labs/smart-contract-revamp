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

    /// @notice Emitted when an asset is added to the supported whitelist
    /// @param asset The ERC20 token added
    event AssetAdded(address indexed asset);

    /// @notice Emitted when an asset is removed from the supported whitelist
    /// @param asset The ERC20 token removed
    event AssetRemoved(address indexed asset);

    /// @notice Emitted when an authorized caller is added or removed
    /// @param caller The caller address
    /// @param authorized True if added, false if removed
    event AuthorizedCallerUpdated(address indexed caller, bool authorized);

    // ============ Errors ============

    /// @notice Thrown when a zero address is provided where a real address is required
    error ZeroAddress();

    /// @notice Thrown when a zero amount is provided
    error ZeroAmount();

    /// @notice Thrown when a deposit is attempted with a non-whitelisted asset
    error UnsupportedAsset();

    /// @notice Thrown when an unauthorized caller attempts a restricted action
    error Unauthorized();

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

    /// @notice Release tokens to a user WITHOUT debiting BalanceLedger
    /// @dev Used by WithdrawalRegistry for hub-native withdrawals where the
    ///      debit was already performed in `requestWithdrawal`. Only callable
    ///      by the owner or authorized callers.
    /// @param user The recipient of the payout
    /// @param asset The ERC20 token to release
    /// @param amount The amount to release
    function payoutDirect(address user, address asset, uint256 amount) external;

    /// @notice Add or remove an authorized caller for payout/payoutDirect
    /// @dev Only callable by the owner. In M4, WithdrawalRegistry is set as
    ///      an authorized caller.
    /// @param caller The caller address to authorize/deauthorize
    /// @param authorized True to authorize, false to deauthorize
    function setAuthorizedCaller(address caller, bool authorized) external;

    // ============ Asset management ============

    /// @notice Add an asset to the supported whitelist
    /// @dev Only callable by the owner. Reverts on zero address.
    /// @param asset The ERC20 token to whitelist
    function addSupportedAsset(address asset) external;

    /// @notice Remove an asset from the supported whitelist
    /// @dev Only callable by the owner.
    /// @param asset The ERC20 token to remove
    function removeSupportedAsset(address asset) external;

    // ============ Views ============

    /// @notice The BalanceLedger this depositor writes to
    function balanceLedger() external view returns (address);

    /// @notice Check whether an asset is on the supported whitelist
    /// @param asset The ERC20 token to check
    /// @return True if the asset is supported
    function isSupportedAsset(address asset) external view returns (bool);

    /// @notice Check whether an address is an authorized caller
    /// @param caller The address to check
    /// @return True if the caller is authorized
    function isAuthorizedCaller(address caller) external view returns (bool);
}
