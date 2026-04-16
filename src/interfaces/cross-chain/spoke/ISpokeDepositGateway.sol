// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISpokeVaultStable} from "./ISpokeVaultStable.sol";

/// @title ISpokeDepositGateway
/// @notice Interface for the user-facing entry point on every spoke chain.
/// @dev On `deposit`, the gateway:
///
///      1. Validates the asset is registered (matching the vault's
///         classification mapping).
///      2. Pulls tokens from the user via `safeTransferFrom`.
///      3. Forwards them to `SpokeVaultStable` via `depositBridged` or
///         `depositSpokeNative`, which records the inflow under the right
///         custody bucket.
///      4. Allocates a deterministic `depositId =
///         keccak256(block.chainid, user, nonce)`, persists a `PendingDeposit`,
///         and sends a LayerZero V2 packet to the hub-side
///         `HubIntentSettler.confirmDeposit` (PR 3 wires the receiver).
///
///      `permitAndDeposit` extends `deposit` for ERC20-Permit assets to make
///      the entire flow a single user transaction.
///
///      `refund(depositId)` is a BRIDGED-only escape hatch: after
///      `REFUND_WINDOW` (30 minutes) elapses without the user obtaining a
///      hub-side credit (e.g. LayerZero delivery failed, executor offline),
///      the original caller can recall their tokens. SPOKE_NATIVE deposits
///      cannot be refunded — they enter permanent vault custody by design.
///
///      NOTE: PR 2 ships only the timeout half of the refund safeguard. The
///      hub-side replay guard (`HubIntentSettler._depositStatuses[depositId]
///      != CREDITED`) lands in PR 3, closing the credit-then-refund race.
interface ISpokeDepositGateway {
    // ============ Types ============

    /// @notice Persisted state for a deposit awaiting hub credit / refund.
    struct PendingDeposit {
        address user;
        address asset;
        uint256 amount;
        ISpokeVaultStable.AssetClassification classification;
        uint64 timestamp;
        bool refunded;
    }

    // ============ Events ============

    /// @notice Emitted when a BRIDGED deposit is initiated and an LZ packet
    ///         has been dispatched to the hub.
    event DepositInitiated(
        bytes32 indexed depositId,
        address indexed user,
        address indexed asset,
        uint256 amount,
        uint32 hubEid,
        bytes32 lzGuid
    );

    /// @notice Emitted when a SPOKE_NATIVE deposit is initiated and an LZ
    ///         packet has been dispatched to the hub.
    event SpokeNativeDeposit(
        bytes32 indexed depositId,
        address indexed user,
        address indexed asset,
        uint256 amount,
        uint32 hubEid,
        bytes32 lzGuid
    );

    /// @notice Emitted when a timed-out BRIDGED deposit is refunded back to
    ///         the original user.
    event DepositRefunded(
        bytes32 indexed depositId,
        address indexed user,
        address indexed asset,
        uint256 amount
    );

    /// @notice Emitted when the owner registers or updates an asset
    ///         classification on the gateway. Must mirror the vault.
    event AssetClassificationSet(
        address indexed asset,
        ISpokeVaultStable.AssetClassification classification
    );

    /// @notice Emitted when a per-eid LayerZero peer is set.
    event PeerSet(uint32 indexed eid, bytes32 peer);

    /// @notice Emitted when the owner updates the LayerZero endpoint pointer.
    event EndpointSet(address endpoint);

    /// @notice Emitted when the owner updates the vault pointer.
    event VaultSet(address vault);

    /// @notice Emitted when the owner updates the hub LayerZero eid.
    event HubEidSet(uint32 hubEid);

    // ============ Errors ============

    error ZeroAddress();
    error ZeroAmount();
    error UnsupportedAsset();
    error UnknownDeposit();
    error AlreadyRefunded();
    error RefundNotYetAllowed(uint64 unlockAt);
    error RefundNotPermittedForSpokeNative();
    error NotOriginalDepositor();
    error InsufficientLzFee(uint256 provided, uint256 required);
    error PeerNotSet(uint32 eid);

    // ============ User actions ============

    /// @notice Deposit `amount` of `asset` on this spoke and dispatch a
    ///         credit message to the hub. Caller must approve the gateway
    ///         for `amount` first. `msg.value` covers the LayerZero native fee.
    /// @return depositId Deterministic id (also used in the LZ payload)
    function deposit(
        address asset,
        uint256 amount
    ) external payable returns (bytes32 depositId);

    /// @notice ERC20-Permit variant. Single-tx flow: permit, pull, escrow,
    ///         dispatch. `msg.value` covers the LayerZero native fee.
    function permitAndDeposit(
        address asset,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external payable returns (bytes32 depositId);

    /// @notice Refund a BRIDGED deposit that has timed out. Original
    ///         depositor only. Reverts before `REFUND_WINDOW` elapses or for
    ///         SPOKE_NATIVE classifications.
    function refund(bytes32 depositId) external;

    // ============ Admin ============

    /// @notice Register or update the routing classification for an asset.
    ///         Must mirror the vault. Owner-only.
    function setAssetClassification(
        address asset,
        ISpokeVaultStable.AssetClassification classification
    ) external;

    /// @notice Set the LayerZero peer for a given destination eid (owner-only).
    function setPeer(uint32 eid, bytes32 peer) external;

    /// @notice Set the LayerZero endpoint pointer (owner-only).
    function setEndpoint(address endpoint) external;

    /// @notice Set the SpokeVaultStable pointer (owner-only).
    function setVault(address vault) external;

    /// @notice Set the destination LayerZero eid for the hub (owner-only).
    function setHubEid(uint32 hubEid) external;

    // ============ Views ============

    /// @notice Refund window (seconds). Constant 30 minutes in PR 2.
    function REFUND_WINDOW() external view returns (uint64);

    /// @notice Look up a pending deposit by id.
    function pendingDeposit(
        bytes32 depositId
    ) external view returns (PendingDeposit memory);

    /// @notice Per-user nonce used to derive `depositId`.
    function userNonce(address user) external view returns (uint256);

    /// @notice Routing classification known to the gateway for `asset`.
    function classificationOf(
        address asset
    ) external view returns (ISpokeVaultStable.AssetClassification);

    /// @notice Quote the LayerZero native fee for a deposit message.
    function quoteDeposit(
        address asset,
        uint256 amount
    ) external view returns (uint256 nativeFee);

    /// @notice Currently registered LayerZero peer for `eid`.
    function peers(uint32 eid) external view returns (bytes32);

    /// @notice LayerZero endpoint pointer.
    function endpoint() external view returns (address);

    /// @notice Vault pointer.
    function vault() external view returns (address);

    /// @notice Destination hub eid.
    function hubEid() external view returns (uint32);
}
