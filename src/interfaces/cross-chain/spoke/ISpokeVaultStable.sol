// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ISpokeVaultStable
/// @notice Interface for the dual-custody spoke vault used by the Centuari
///         cross-chain BalanceLedger. Holds tokens deposited on a spoke chain,
///         segregated by routing classification.
/// @dev Two custody modes coexist in one contract:
///
///      - `BRIDGED`: USDC / USDT / WETH / WBTC. Balances accumulate until the
///        Sweeper Bot (M7) drains them via CCTP v2 (USDC on Base/Ethereum/
///        Polygon — zero fee burn/mint) or Stargate V2 (everything else —
///        ~0.06% pool fee). Sweeps are gated to `_sweeper`.
///      - `SPOKE_NATIVE`: chain-specific tokens that NEVER bridge (e.g. XSGD
///        on Base). They stay in permanent vault custody and are released
///        back to users locally via `releaseSpokeNative`, which is gated to
///        `_payout` (the future `SpokePayout` contract — wired in PR 4).
///
///      Inflows arrive from `_gateway` (the `SpokeDepositGateway` user entry),
///      which calls `depositBridged` or `depositSpokeNative` after pulling
///      tokens from the user via `safeTransferFrom`.
interface ISpokeVaultStable {
    // ============ Types ============

    /// @notice Routing classification for a registered asset.
    /// @dev `UNSUPPORTED` is the default zero value — any deposit/sweep call
    ///      against an unregistered asset reverts with `UnsupportedAsset`.
    enum AssetClassification {
        UNSUPPORTED,
        BRIDGED,
        SPOKE_NATIVE
    }

    // ============ Events ============

    /// @notice Emitted when the gateway escrows a BRIDGED token in the vault.
    event BridgedDeposited(
        address indexed asset,
        address indexed from,
        uint256 amount
    );

    /// @notice Emitted when the gateway escrows a SPOKE_NATIVE token.
    event SpokeNativeDeposited(
        address indexed asset,
        address indexed from,
        uint256 amount
    );

    /// @notice Emitted when the sweeper drains a BRIDGED balance via CCTP.
    event SweptCCTP(
        address indexed asset,
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        uint64 nonce
    );

    /// @notice Emitted when the sweeper drains a BRIDGED balance via Stargate.
    event SweptStargate(
        address indexed asset,
        uint256 amount,
        uint32 dstEid,
        bytes32 to,
        uint256 amountReceived
    );

    /// @notice Emitted when the payout contract releases a SPOKE_NATIVE token
    ///         back to a user (PR 4 wires the actual caller).
    event SpokeNativeReleased(
        address indexed asset,
        address indexed to,
        uint256 amount
    );

    /// @notice Emitted when the owner registers or updates an asset classification.
    event AssetClassificationSet(
        address indexed asset,
        AssetClassification classification
    );

    /// @notice Emitted when the owner sets a per-asset Stargate router.
    event StargateRouterSet(address indexed asset, address router);

    /// @notice Emitted when the owner updates the CCTP messenger.
    event CctpMessengerSet(address messenger);

    /// @notice Emitted when the owner updates the gateway role.
    event GatewaySet(address gateway);

    /// @notice Emitted when the owner updates the sweeper role.
    event SweeperSet(address sweeper);

    /// @notice Emitted when the owner updates the payout role.
    event PayoutSet(address payout);

    // ============ Errors ============

    error ZeroAddress();
    error ZeroAmount();
    error Unauthorized();
    error UnsupportedAsset();
    error CannotSweepSpokeNative();
    error CannotReleaseBridged();
    error InsufficientBridgedBalance(uint256 available, uint256 requested);
    error InsufficientSpokeNativeBalance(uint256 available, uint256 requested);
    error StargateRouterNotSet(address asset);
    error CctpMessengerNotSet();

    // ============ Gateway-only inflows ============

    /// @notice Record a BRIDGED inflow. The gateway has already pulled tokens
    ///         from `from` and forwarded them to this vault via
    ///         `safeTransferFrom(gateway, vault, amount)`.
    /// @dev Asserts the asset is registered as `BRIDGED`. Increments the
    ///      bridged custody balance for the asset.
    function depositBridged(
        address asset,
        address from,
        uint256 amount
    ) external;

    /// @notice Record a SPOKE_NATIVE inflow. Same custody mechanics as
    ///         `depositBridged` but the asset must be registered SPOKE_NATIVE.
    function depositSpokeNative(
        address asset,
        address from,
        uint256 amount
    ) external;

    /// @notice Return BRIDGED escrow back to the original depositor. Only
    ///         callable by the gateway; only valid for assets currently
    ///         registered BRIDGED. Used by `SpokeDepositGateway.refund` to
    ///         honour a timed-out deposit.
    function recallBridged(
        address asset,
        address to,
        uint256 amount
    ) external;

    /// @notice Emitted when the gateway recalls BRIDGED escrow on refund.
    event BridgedRecalled(
        address indexed asset,
        address indexed to,
        uint256 amount
    );

    // ============ Sweeper-only outflows (BRIDGED) ============

    /// @notice Burn the entire BRIDGED custody for `asset` via CCTP v2.
    /// @dev Calls `TokenMessengerV2.depositForBurn`. Asset must be BRIDGED
    ///      and the CCTP messenger must be set. Drains the vault balance to
    ///      zero in a single call.
    /// @param asset The BRIDGED ERC20 to burn (must be USDC on a CCTP-supported domain)
    /// @param destinationDomain CCTP domain id of the hub (Arbitrum = 3)
    /// @param mintRecipient Hub-side recipient as bytes32
    /// @return amount Amount burned
    /// @return nonce CCTP nonce returned by the messenger
    function sweepCCTP(
        address asset,
        uint32 destinationDomain,
        bytes32 mintRecipient
    ) external returns (uint256 amount, uint64 nonce);

    /// @notice Bridge the entire BRIDGED custody for `asset` via Stargate V2.
    /// @dev Calls `IStargate.send`. Asset must be BRIDGED and a per-asset
    ///      Stargate router must be set. Drains the vault balance to zero.
    /// @param asset The BRIDGED ERC20 to bridge
    /// @param dstEid LayerZero destination endpoint id of the hub
    /// @param to Hub-side recipient as bytes32
    /// @param minAmountOut Minimum acceptable received amount (slippage gate)
    /// @param nativeFee Native gas fee forwarded to Stargate (also from msg.value)
    /// @return amountSent Amount of `asset` sent
    /// @return amountReceived Amount expected on the destination after fees
    function sweepStargate(
        address asset,
        uint32 dstEid,
        bytes32 to,
        uint256 minAmountOut,
        uint256 nativeFee
    ) external payable returns (uint256 amountSent, uint256 amountReceived);

    // ============ Payout-only outflows (SPOKE_NATIVE) ============

    /// @notice Release SPOKE_NATIVE custody back to a user. Caller must be
    ///         the registered `_payout` address (wired in PR 4).
    /// @dev Asserts the asset is SPOKE_NATIVE; reverts for BRIDGED.
    function releaseSpokeNative(
        address asset,
        address to,
        uint256 amount
    ) external;

    // ============ Admin ============

    /// @notice Register or change the routing classification for an asset.
    ///         Owner-only. Setting `UNSUPPORTED` effectively unregisters.
    function setAssetClassification(
        address asset,
        AssetClassification classification
    ) external;

    /// @notice Set the per-asset Stargate router (owner-only).
    function setStargateRouter(address asset, address router) external;

    /// @notice Set the CCTP messenger (owner-only).
    function setCctpMessenger(address messenger) external;

    /// @notice Set the gateway role (owner-only).
    function setGateway(address gateway) external;

    /// @notice Set the sweeper role (owner-only).
    function setSweeper(address sweeper) external;

    /// @notice Set the payout role (owner-only).
    function setPayout(address payout) external;

    // ============ Views ============

    /// @notice Bridged custody balance held for `asset`.
    function bridgedBalance(address asset) external view returns (uint256);

    /// @notice Spoke-native custody balance held for `asset`.
    function spokeNativeBalance(address asset) external view returns (uint256);

    /// @notice Routing classification for `asset`.
    function classificationOf(
        address asset
    ) external view returns (AssetClassification);

    /// @notice Currently registered Stargate router for `asset`.
    function stargateRouterOf(address asset) external view returns (address);

    /// @notice Currently registered CCTP messenger.
    function cctpMessenger() external view returns (address);

    /// @notice Currently registered gateway role.
    function gateway() external view returns (address);

    /// @notice Currently registered sweeper role.
    function sweeper() external view returns (address);

    /// @notice Currently registered payout role.
    function payout() external view returns (address);
}
