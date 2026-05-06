// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ISpokePayout
/// @notice Interface for the spoke-side LZ receiver that releases tokens to
///         users after a cross-chain withdrawal has been authorized on the hub.
/// @dev Two release paths:
///
///      - **BRIDGED**: tokens come from an internal `_bridgedBuffer[asset]`,
///        replenished by the Sweeper Bot after bridging hub liquidity to the
///        spoke via CCTP / Stargate. If the buffer is short, the payout is
///        enqueued in `_pendingPayouts` and emitted as `PayoutQueued`.
///        `flushPending` drains the queue once the buffer is topped up.
///
///      - **SPOKE_NATIVE**: tokens are released from `SpokeVaultStable`
///        permanent custody via `releaseSpokeNative`. No queue — reverts if
///        the vault has insufficient custody (should never happen in normal
///        operation since the tokens never left the spoke).
interface ISpokePayout {
    // ============ Types ============

    /// @notice A queued payout waiting for bridged buffer replenishment.
    struct PendingPayout {
        address user;
        address asset;
        uint256 amount;
        bytes32 requestId;
    }

    // ============ Events ============

    /// @notice Emitted when tokens are released to a user immediately.
    event PayoutReleased(bytes32 indexed requestId, address indexed user, address indexed asset, uint256 amount);

    /// @notice Emitted when a BRIDGED payout is queued due to insufficient
    ///         buffer.
    event PayoutQueued(bytes32 indexed requestId, address indexed user, address indexed asset, uint256 amount);

    /// @notice Emitted when a previously queued payout is flushed.
    event PendingPayoutFlushed(bytes32 indexed requestId, address indexed user, address indexed asset, uint256 amount);

    /// @notice Emitted when the sweeper replenishes the bridged buffer.
    event BridgedBufferReplenished(address indexed asset, uint256 amount, uint256 newTotal);

    /// @notice Emitted when the owner sets the vault pointer.
    event VaultSet(address vault);

    /// @notice Emitted when the owner sets the sweeper role.
    event SweeperSet(address sweeper);

    /// @notice Emitted when the owner sets the LZ endpoint pointer.
    event EndpointSet(address endpoint);

    /// @notice Emitted when the owner sets a peer.
    event PeerSet(uint32 indexed eid, bytes32 peer);

    // ============ Errors ============

    error ZeroAddress();
    error ZeroAmount();
    error Unauthorized();
    error InvalidLzEndpoint();
    error UntrustedRemote(uint32 eid, bytes32 sender);
    error NoPendingPayouts(address user, address asset);

    // ============ Sweeper actions ============

    /// @notice Replenish the bridged buffer for `asset`. The sweeper must
    ///         have approved this contract for `amount` before calling.
    function replenishBridgedBuffer(address asset, uint256 amount) external;

    /// @notice Flush all pending BRIDGED payouts for `(user, asset)` up to
    ///         the available buffer. Callable by anyone (sweeper, keeper, user).
    function flushPending(address user, address asset) external;

    // ============ Admin ============

    function setVault(address vault) external;
    function setSweeper(address sweeper) external;
    function setEndpoint(address endpoint) external;
    function setPeer(uint32 eid, bytes32 peer) external;

    // ============ Views ============

    function bridgedBuffer(address asset) external view returns (uint256);
    function pendingPayoutCount(address user, address asset) external view returns (uint256);
    function vault() external view returns (address);
    function sweeper() external view returns (address);
    function endpoint() external view returns (address);
    function peers(uint32 eid) external view returns (bytes32);
}
