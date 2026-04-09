// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IBalanceLedger
/// @notice Single source of truth for all user balances in the Centuari protocol
/// @dev Tracks stablecoin balances with 4 sub-states and collateral positions.
///      Write access restricted to CentuariEndpoint, WithdrawalRegistry, YieldRouter, LiquidationEngine.
interface IBalanceLedger {
    // ============ Structs ============

    /// @notice Per-user per-asset balance with 4 sub-states
    /// @param available Liquid balance — can be withdrawn or used for orders
    /// @param locked Reserved for open orders (TOCTOU protection)
    /// @param inYieldRouter Deployed to external protocols via YieldRouter
    /// @param yieldRouterShares Share tokens held per adapter
    struct UserBalance {
        uint256 available;
        uint256 locked;
        uint256 inYieldRouter;
        uint256 yieldRouterShares;
    }

    /// @notice Collateral position for RWA and other collateral types
    /// @param asset The collateral asset address
    /// @param amount Total amount deposited as collateral
    /// @param lockedShares For share-price assets (e.g., OUSG)
    /// @param lastAttestationTs For ATTESTATION-mode assets
    /// @param usdValueCached Last known USD value (updated by keeper)
    /// @param sourceChainId Chain where underlying is held
    /// @param spokeVaultId SpokeVault contract address on source chain
    /// @param state Current state of the collateral
    struct CollateralPosition {
        address asset;
        uint256 amount;
        uint256 lockedShares;
        uint256 lastAttestationTs;
        uint256 usdValueCached;
        uint256 sourceChainId;
        bytes32 spokeVaultId;
        CollateralState state;
    }

    // ============ Enums ============

    enum CollateralState {
        ACTIVE,
        FROZEN,
        LIQUIDATING
    }

    // ============ Balance Operations ============

    /// @notice Credit tokens to a user's available balance
    /// @param user The user address
    /// @param asset The token address
    /// @param amount The amount to credit
    function credit(address user, address asset, uint256 amount) external;

    /// @notice Debit tokens from a user's available balance
    /// @param user The user address
    /// @param asset The token address
    /// @param amount The amount to debit
    function debit(address user, address asset, uint256 amount) external;

    /// @notice Lock funds for an order — moves from available to locked (TOCTOU fix)
    /// @param user The user address
    /// @param asset The token address
    /// @param amount The amount to lock
    function lockForOrder(address user, address asset, uint256 amount) external;

    /// @notice Unlock funds from a cancelled order — moves from locked to available
    /// @param user The user address
    /// @param asset The token address
    /// @param amount The amount to unlock
    function unlockFromOrder(address user, address asset, uint256 amount) external;

    /// @notice Move funds to YieldRouter — moves from available to inYieldRouter
    /// @param user The user address
    /// @param asset The token address
    /// @param amount The amount to move
    /// @param shares The adapter shares received
    function moveToYieldRouter(address user, address asset, uint256 amount, uint256 shares) external;

    /// @notice Move funds from YieldRouter — moves from inYieldRouter to available
    /// @param user The user address
    /// @param asset The token address
    /// @param amount The amount returned (may include yield)
    /// @param shares The adapter shares burned
    function moveFromYieldRouter(address user, address asset, uint256 amount, uint256 shares) external;

    // ============ Collateral Operations ============

    /// @notice Add collateral position
    /// @param user The user address
    /// @param asset The collateral asset
    /// @param amount The amount
    /// @param sourceChainId The chain where underlying is held
    function addCollateral(address user, address asset, uint256 amount, uint256 sourceChainId) external;

    /// @notice Toggle whether an asset is used as collateral for health factor
    /// @dev Cannot disable if it would put existing borrows below HF 1.0
    /// @param asset The asset address
    /// @param useAsCollateral Whether to use as collateral
    function setAsCollateral(address asset, bool useAsCollateral) external;

    /// @notice Freeze collateral — issuer blocklisted the asset
    /// @param user The user address
    /// @param collateralIndex Index in user's collateral array
    function freezeCollateral(address user, uint256 collateralIndex) external;

    /// @notice Reduce collateral after liquidation
    /// @param user The user address
    /// @param asset The collateral asset
    /// @param amount The amount to reduce
    function reduceCollateral(address user, address asset, uint256 amount) external;

    /// @notice Update cached USD value for a collateral position
    /// @param user The user address
    /// @param asset The collateral asset
    /// @param newUsdValue The new USD value
    function updateCollateralUsdValue(address user, address asset, uint256 newUsdValue) external;

    /// @notice Transfer ERC20 tokens out of the ledger (for CBT redemption)
    /// @dev Only callable by authorized writers (CentuariEndpoint).
    ///      Does NOT modify any user balance — transfers from the ledger's own ERC20 holdings.
    /// @param asset The token to transfer
    /// @param to The recipient
    /// @param amount The amount
    function transferOut(address asset, address to, uint256 amount) external;

    /// @notice Deposit tokens — transfers ERC20 from msg.sender, credits available balance
    /// @dev User-callable (not onlyAuthorized). Also callable by pCBT vault.
    function deposit(address asset, uint256 amount) external;

    /// @notice Atomic deposit + collateral registration in one transaction
    /// @dev User-callable. Requires real ERC20 transfer (prevents circular collateral).
    function depositAsCollateral(address asset, uint256 amount) external;

    /// @notice Withdraw tokens — debits available balance, transfers ERC20 to msg.sender
    function withdraw(address asset, uint256 amount) external;

    /// @notice Toggle yield router for an asset (user opt-in/opt-out)
    function setYieldEnabled(address asset, bool enabled) external;

    // ============ View Functions ============

    /// @notice Get user's full balance for an asset
    function getBalance(address user, address asset) external view returns (UserBalance memory);

    /// @notice Get user's available balance for an asset
    function getAvailable(address user, address asset) external view returns (uint256);

    /// @notice Get user's locked balance for an asset
    function getLocked(address user, address asset) external view returns (uint256);

    /// @notice Get user's collateral positions
    function getCollateral(address user) external view returns (CollateralPosition[] memory);

    /// @notice Get collateral position by asset
    function getCollateralByAsset(address user, address asset) external view returns (CollateralPosition memory);

    /// @notice Check if asset is used as collateral for a user
    function getIsUsedAsCollateral(address user, address asset) external view returns (bool);

    /// @notice Check if an address is an authorized writer
    function isAuthorizedWriter(address writer) external view returns (bool);

    // ============ Events ============

    event BalanceCredited(address indexed user, address indexed asset, uint256 amount);
    event BalanceDebited(address indexed user, address indexed asset, uint256 amount);
    event OrderLocked(address indexed user, address indexed asset, uint256 amount);
    event OrderUnlocked(address indexed user, address indexed asset, uint256 amount);
    event YieldRouterDeposited(address indexed user, address indexed asset, uint256 amount, uint256 shares);
    event YieldRouterWithdrawn(address indexed user, address indexed asset, uint256 amount, uint256 shares);
    event CollateralAdded(address indexed user, address indexed asset, uint256 amount, uint256 sourceChainId);
    event CollateralReduced(address indexed user, address indexed asset, uint256 amount);
    event CollateralToggled(address indexed user, address indexed asset, bool useAsCollateral);
    event CollateralFrozen(address indexed user, address indexed asset, uint256 amount);
    event AuthorizedWriterUpdated(address indexed writer, bool authorized);
    event AuthorizedWriterProposed(address indexed writer, bool authorized, uint256 unlockTime);
    event AdminChangeProposed(bytes32 indexed key, address indexed newAddr, uint256 unlockTime);
    event AdminChangeApplied(bytes32 indexed key, address indexed newAddr);
    event AdminChangeCancelled(bytes32 indexed key);

    // ============ Errors ============

    error Unauthorized();
    error ZeroAddress();
    error ZeroAmount();
    error InsufficientAvailable();
    error InsufficientLocked();
    error InsufficientYieldRouter();
    error InsufficientCollateral();
    error WouldCauseUndercollateralization();
    error CollateralNotActive();
    error AssetNotCollateralEligible();
    error CollateralNotFound();
}
