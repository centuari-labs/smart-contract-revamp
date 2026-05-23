// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ISpokePayout} from "../../../interfaces/cross-chain/spoke/ISpokePayout.sol";
import {ISpokeVaultStable} from "../../../interfaces/cross-chain/spoke/ISpokeVaultStable.sol";
import {SpokePayoutStorage} from "./SpokePayoutStorage.sol";
import {ReentrancyGuardUpgradeable} from "../../../utils/ReentrancyGuardUpgradeable.sol";

/// @title SpokePayout
/// @notice LZ receiver on the spoke that releases tokens to users after a
///         cross-chain withdrawal has been authorized on the hub.
/// @dev See `ISpokePayout` for the dual release path (BRIDGED buffer vs
///      SPOKE_NATIVE vault custody).
contract SpokePayout is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    SpokePayoutStorage,
    ISpokePayout
{
    using SafeERC20 for IERC20;

    /// @notice SPOKE_NATIVE classification constant (mirrors ISpokeVaultStable).
    uint8 internal constant _SPOKE_NATIVE = 2;

    // ============ LZ Origin struct ============

    /// @notice Minimal LZ V2 Origin (matches MockLZEndpoint.Origin).
    struct Origin {
        uint32 srcEid;
        bytes32 sender;
        uint64 nonce;
    }

    // ============ Constructor ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initializer ============

    function initialize(address owner_, address vault_, address endpoint_) external initializer {
        if (owner_ == address(0)) revert ZeroAddress();
        if (vault_ == address(0)) revert ZeroAddress();
        if (endpoint_ == address(0)) revert ZeroAddress();

        __Ownable_init(owner_);
        __ReentrancyGuard_init();

        _vault = vault_;
        _lzEndpoint = endpoint_;
    }

    // ============ Modifiers ============

    modifier onlySweeper() {
        if (msg.sender != _sweeper) revert Unauthorized();
        _;
    }

    // ============ LZ receive ============

    /// @notice LayerZero V2 ILayerZeroReceiver hook. Endpoint calls this on
    ///         every brand-new (srcEid, sender, nonce) tuple to decide
    ///         whether a delivery path can be initialized for this receiver.
    ///         We allow only senders matching a registered trusted peer.
    /// @dev Without this method EndpointV2._initializable returns false, so
    ///      LZ scanner reports "Not Initializable" and no relay completes.
    function allowInitializePath(Origin calldata origin) external view returns (bool) {
        bytes32 expected = _peers[origin.srcEid];
        return expected != bytes32(0) && origin.sender == expected;
    }

    /// @notice Receive a payout message from the hub's WithdrawalRegistry.
    /// @dev Payload schema: `(requestId, user, asset, amount, classification)`.
    /// @dev LayerZero V2 ILayerZeroReceiver standard signature is
    ///      `(Origin, bytes32 guid, bytes message, address executor, bytes extraData)`.
    ///      The earlier draft used a different non-standard ordering which
    ///      caused the EndpointV2 calldata to ABI-decode incorrectly and
    ///      revert silently with empty data.
    function lzReceive(
        Origin calldata origin,
        bytes32, // guid — unused
        bytes calldata message,
        address, // executor — unused
        bytes calldata // extraData — unused
    )
        external
        payable
        nonReentrant
    {
        if (msg.sender != _lzEndpoint) revert InvalidLzEndpoint();
        bytes32 expectedPeer = _peers[origin.srcEid];
        if (expectedPeer == bytes32(0) || origin.sender != expectedPeer) {
            revert UntrustedRemote(origin.srcEid, origin.sender);
        }

        (bytes32 requestId, address user, address asset, uint256 amount, uint8 classification) =
            abi.decode(message, (bytes32, address, address, uint256, uint8));

        if (classification == _SPOKE_NATIVE) {
            // Release from vault permanent custody — reverts if short.
            ISpokeVaultStable(_vault).releaseSpokeNative(asset, user, amount);
            emit PayoutReleased(requestId, user, asset, amount);
        } else {
            // BRIDGED: try buffer, queue if insufficient.
            uint256 available = _bridgedBuffer[asset];
            if (available >= amount) {
                _bridgedBuffer[asset] = available - amount;
                IERC20(asset).safeTransfer(user, amount);
                emit PayoutReleased(requestId, user, asset, amount);
            } else {
                _pendingPayouts[user][asset].push(
                    PendingPayout({user: user, asset: asset, amount: amount, requestId: requestId})
                );
                emit PayoutQueued(requestId, user, asset, amount);
            }
        }
    }

    // ============ Sweeper actions ============

    /// @inheritdoc ISpokePayout
    function replenishBridgedBuffer(address asset, uint256 amount) external onlySweeper nonReentrant {
        if (asset == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        _bridgedBuffer[asset] += amount;

        emit BridgedBufferReplenished(asset, amount, _bridgedBuffer[asset]);
    }

    /// @inheritdoc ISpokePayout
    function flushPending(address user, address asset) external nonReentrant {
        PendingPayout[] storage queue = _pendingPayouts[user][asset];
        uint256 len = queue.length;
        if (len == 0) revert NoPendingPayouts(user, asset);

        uint256 flushed;
        for (uint256 i = 0; i < len;) {
            PendingPayout memory pp = queue[i];
            uint256 available = _bridgedBuffer[asset];
            if (available < pp.amount) break; // no more buffer

            _bridgedBuffer[asset] = available - pp.amount;
            IERC20(asset).safeTransfer(pp.user, pp.amount);
            emit PendingPayoutFlushed(pp.requestId, pp.user, pp.asset, pp.amount);
            unchecked {
                flushed++;
                i++;
            }
        }

        // Compact the queue: shift remaining items left.
        if (flushed > 0 && flushed < len) {
            for (uint256 j = 0; j < len - flushed; j++) {
                queue[j] = queue[j + flushed];
            }
        }
        // Pop flushed entries.
        for (uint256 k = 0; k < flushed; k++) {
            queue.pop();
        }
    }

    // ============ Admin ============

    /// @inheritdoc ISpokePayout
    function setVault(address vault_) external onlyOwner {
        if (vault_ == address(0)) revert ZeroAddress();
        _vault = vault_;
        emit VaultSet(vault_);
    }

    /// @inheritdoc ISpokePayout
    function setSweeper(address sweeper_) external onlyOwner {
        _sweeper = sweeper_;
        emit SweeperSet(sweeper_);
    }

    /// @inheritdoc ISpokePayout
    function setEndpoint(address endpoint_) external onlyOwner {
        if (endpoint_ == address(0)) revert ZeroAddress();
        _lzEndpoint = endpoint_;
        emit EndpointSet(endpoint_);
    }

    /// @inheritdoc ISpokePayout
    function setPeer(uint32 eid, bytes32 peer) external onlyOwner {
        _peers[eid] = peer;
        emit PeerSet(eid, peer);
    }

    // ============ Views ============

    /// @inheritdoc ISpokePayout
    function bridgedBuffer(address asset) external view returns (uint256) {
        return _bridgedBuffer[asset];
    }

    /// @inheritdoc ISpokePayout
    function pendingPayoutCount(address user, address asset) external view returns (uint256) {
        return _pendingPayouts[user][asset].length;
    }

    /// @inheritdoc ISpokePayout
    function vault() external view returns (address) {
        return _vault;
    }

    /// @inheritdoc ISpokePayout
    function sweeper() external view returns (address) {
        return _sweeper;
    }

    /// @inheritdoc ISpokePayout
    function endpoint() external view returns (address) {
        return _lzEndpoint;
    }

    /// @inheritdoc ISpokePayout
    function peers(uint32 eid) external view returns (bytes32) {
        return _peers[eid];
    }
}
