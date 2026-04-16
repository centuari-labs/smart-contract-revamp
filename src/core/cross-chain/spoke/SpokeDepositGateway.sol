// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    Initializable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {
    IERC20
} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    IERC20Permit
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ISpokeDepositGateway} from "../../../interfaces/cross-chain/spoke/ISpokeDepositGateway.sol";
import {ISpokeVaultStable} from "../../../interfaces/cross-chain/spoke/ISpokeVaultStable.sol";
import {SpokeDepositGatewayStorage} from "./SpokeDepositGatewayStorage.sol";
import {ReentrancyGuardUpgradeable} from "../../../utils/ReentrancyGuardUpgradeable.sol";

/// @notice Minimal LayerZero V2 endpoint surface used by the gateway. The
///         shape mirrors `ILayerZeroEndpointV2.send` and the in-repo
///         `MockLZEndpoint` from PR 1, so the same call site exercises both
///         under tests and on a live spoke deployment.
interface ILzEndpointLite {
    struct MessagingParams {
        uint32 dstEid;
        bytes32 receiver;
        bytes message;
        bytes options;
        bool payInLzToken;
    }

    struct MessagingFee {
        uint256 nativeFee;
        uint256 lzTokenFee;
    }

    struct MessagingReceipt {
        bytes32 guid;
        uint64 nonce;
        MessagingFee fee;
    }

    function quote(
        MessagingParams calldata params,
        address sender
    ) external view returns (MessagingFee memory);

    function send(
        MessagingParams calldata params,
        address refundAddress
    ) external payable returns (MessagingReceipt memory);
}

/// @title SpokeDepositGateway
/// @notice User entry point on every spoke chain. Routes deposits into the
///         right `SpokeVaultStable` custody bucket and dispatches a LayerZero
///         credit message to the hub.
/// @dev See `ISpokeDepositGateway` for the data flow. Replay protection of
///      the refund path closes in PR 3 once `HubIntentSettler.confirmDeposit`
///      starts marking `_depositStatuses[depositId] = CREDITED`. Until then,
///      the 30-min `REFUND_WINDOW` is the sole defence against double-spend
///      and is documented in tests.
contract SpokeDepositGateway is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    SpokeDepositGatewayStorage,
    ISpokeDepositGateway
{
    using SafeERC20 for IERC20;

    /// @inheritdoc ISpokeDepositGateway
    uint64 public constant override REFUND_WINDOW = 30 minutes;

    // ============ Constructor ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initializer ============

    /// @notice Initialise the gateway with all mandatory wiring. Asset
    ///         classifications and peers are configured separately by the
    ///         owner.
    function initialize(
        address owner_,
        address vault_,
        address endpoint_,
        uint32 hubEid_
    ) external initializer {
        if (owner_ == address(0)) revert ZeroAddress();
        if (vault_ == address(0)) revert ZeroAddress();
        if (endpoint_ == address(0)) revert ZeroAddress();

        __Ownable_init(owner_);
        __ReentrancyGuard_init();

        _vault = vault_;
        _endpoint = endpoint_;
        _hubEid = hubEid_;
    }

    // ============ User actions ============

    /// @inheritdoc ISpokeDepositGateway
    function deposit(
        address asset,
        uint256 amount
    ) external payable nonReentrant returns (bytes32 depositId) {
        return _deposit(asset, amount);
    }

    /// @inheritdoc ISpokeDepositGateway
    function permitAndDeposit(
        address asset,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external payable nonReentrant returns (bytes32 depositId) {
        // Best-effort permit — silently ignore failure so that a frontend
        // re-submitting after a permit has already been consumed in a
        // racing tx still succeeds via the existing allowance.
        try
            IERC20Permit(asset).permit(
                msg.sender,
                address(this),
                amount,
                deadline,
                v,
                r,
                s
            )
        {} catch {}

        return _deposit(asset, amount);
    }

    /// @inheritdoc ISpokeDepositGateway
    function refund(bytes32 depositId) external nonReentrant {
        PendingDeposit storage pd = _pendingDeposits[depositId];
        if (pd.user == address(0)) revert UnknownDeposit();
        if (pd.refunded) revert AlreadyRefunded();
        if (msg.sender != pd.user) revert NotOriginalDepositor();
        if (
            pd.classification ==
            ISpokeVaultStable.AssetClassification.SPOKE_NATIVE
        ) {
            revert RefundNotPermittedForSpokeNative();
        }
        uint64 unlockAt = pd.timestamp + REFUND_WINDOW;
        if (block.timestamp < unlockAt) revert RefundNotYetAllowed(unlockAt);

        pd.refunded = true;

        // The vault holds the tokens. PR 2 adds a vault-side hook so the
        // gateway can recall its own escrow without relying on the sweeper /
        // payout roles. We model that hook with a low-level call into the
        // vault's `_bridgedBalance` accounting via the same gateway role.
        //
        // NOTE: PR 2 keeps refund accounting on the gateway side only — the
        // vault's `_bridgedBalance` is decremented during the recall via the
        // dedicated `vaultRecall` selector below. PR 4 may collapse this back
        // into a single `vault.recall` call once SpokePayout exists.
        _recallFromVault(pd.asset, pd.user, pd.amount);

        emit DepositRefunded(depositId, pd.user, pd.asset, pd.amount);
    }

    // ============ Internal core ============

    function _deposit(
        address asset,
        uint256 amount
    ) internal returns (bytes32 depositId) {
        if (asset == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        ISpokeVaultStable.AssetClassification cls = _classifications[asset];
        if (cls == ISpokeVaultStable.AssetClassification.UNSUPPORTED) {
            revert UnsupportedAsset();
        }
        if (_peers[_hubEid] == bytes32(0)) revert PeerNotSet(_hubEid);

        // Pull tokens from the user, then forward into the vault under the
        // matching custody bucket.
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(asset).forceApprove(_vault, amount);

        if (cls == ISpokeVaultStable.AssetClassification.BRIDGED) {
            ISpokeVaultStable(_vault).depositBridged(
                asset,
                msg.sender,
                amount
            );
        } else {
            ISpokeVaultStable(_vault).depositSpokeNative(
                asset,
                msg.sender,
                amount
            );
        }

        // Allocate a deterministic id and persist the pending state BEFORE
        // dispatching the LZ packet so a revert in `endpoint.send` does not
        // leave us with hanging escrow.
        uint256 nonce = _userNonce[msg.sender]++;
        depositId = keccak256(abi.encode(block.chainid, msg.sender, nonce));

        _pendingDeposits[depositId] = PendingDeposit({
            user: msg.sender,
            asset: asset,
            amount: amount,
            classification: cls,
            timestamp: uint64(block.timestamp),
            refunded: false
        });

        // Dispatch the credit message.
        ILzEndpointLite.MessagingReceipt memory receipt = _lzSend(
            depositId,
            asset,
            amount,
            cls
        );

        if (cls == ISpokeVaultStable.AssetClassification.BRIDGED) {
            emit DepositInitiated(
                depositId,
                msg.sender,
                asset,
                amount,
                _hubEid,
                receipt.guid
            );
        } else {
            emit SpokeNativeDeposit(
                depositId,
                msg.sender,
                asset,
                amount,
                _hubEid,
                receipt.guid
            );
        }
    }

    function _lzSend(
        bytes32 depositId,
        address asset,
        uint256 amount,
        ISpokeVaultStable.AssetClassification cls
    ) internal returns (ILzEndpointLite.MessagingReceipt memory receipt) {
        bytes memory payload = abi.encode(
            depositId,
            msg.sender,
            asset,
            amount,
            uint8(cls),
            block.chainid
        );

        ILzEndpointLite.MessagingParams memory params = ILzEndpointLite
            .MessagingParams({
                dstEid: _hubEid,
                receiver: _peers[_hubEid],
                message: payload,
                options: bytes(""),
                payInLzToken: false
            });

        ILzEndpointLite.MessagingFee memory fee = ILzEndpointLite(_endpoint)
            .quote(params, address(this));
        if (msg.value < fee.nativeFee) {
            revert InsufficientLzFee(msg.value, fee.nativeFee);
        }

        receipt = ILzEndpointLite(_endpoint).send{value: fee.nativeFee}(
            params,
            msg.sender
        );

        // Refund any excess native to the original caller.
        uint256 excess = msg.value - fee.nativeFee;
        if (excess > 0) {
            (bool ok, ) = msg.sender.call{value: excess}("");
            // Silently ignore: the user passed extra value, the worst case is
            // the change is left on this contract until rescued. PR 4 wires
            // the rescue path from SpokePayout.
            ok;
        }
    }

    /// @dev Pulls tokens back out of the vault's bridged custody and returns
    ///      them to the original depositor. Only invoked from `refund`.
    function _recallFromVault(
        address asset,
        address to,
        uint256 amount
    ) internal {
        // The vault implements a one-shot "gateway recall" path via a
        // dedicated selector: `recallBridged(asset, to, amount)`. PR 2 wires
        // this on the vault side because the existing payout role only
        // covers SPOKE_NATIVE.
        ISpokeVaultStableRecall(_vault).recallBridged(asset, to, amount);
    }

    // ============ Admin ============

    /// @inheritdoc ISpokeDepositGateway
    function setAssetClassification(
        address asset,
        ISpokeVaultStable.AssetClassification classification
    ) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        _classifications[asset] = classification;
        emit AssetClassificationSet(asset, classification);
    }

    /// @inheritdoc ISpokeDepositGateway
    function setPeer(uint32 eid, bytes32 peer) external onlyOwner {
        _peers[eid] = peer;
        emit PeerSet(eid, peer);
    }

    /// @inheritdoc ISpokeDepositGateway
    function setEndpoint(address endpoint_) external onlyOwner {
        if (endpoint_ == address(0)) revert ZeroAddress();
        _endpoint = endpoint_;
        emit EndpointSet(endpoint_);
    }

    /// @inheritdoc ISpokeDepositGateway
    function setVault(address vault_) external onlyOwner {
        if (vault_ == address(0)) revert ZeroAddress();
        _vault = vault_;
        emit VaultSet(vault_);
    }

    /// @inheritdoc ISpokeDepositGateway
    function setHubEid(uint32 hubEid_) external onlyOwner {
        _hubEid = hubEid_;
        emit HubEidSet(hubEid_);
    }

    // ============ Views ============

    /// @inheritdoc ISpokeDepositGateway
    function pendingDeposit(
        bytes32 depositId
    ) external view returns (PendingDeposit memory) {
        return _pendingDeposits[depositId];
    }

    /// @inheritdoc ISpokeDepositGateway
    function userNonce(address user) external view returns (uint256) {
        return _userNonce[user];
    }

    /// @inheritdoc ISpokeDepositGateway
    function classificationOf(
        address asset
    ) external view returns (ISpokeVaultStable.AssetClassification) {
        return _classifications[asset];
    }

    /// @inheritdoc ISpokeDepositGateway
    function quoteDeposit(
        address asset,
        uint256 amount
    ) external view returns (uint256 nativeFee) {
        ISpokeVaultStable.AssetClassification cls = _classifications[asset];
        bytes memory payload = abi.encode(
            bytes32(0),
            msg.sender,
            asset,
            amount,
            uint8(cls),
            block.chainid
        );
        ILzEndpointLite.MessagingParams memory params = ILzEndpointLite
            .MessagingParams({
                dstEid: _hubEid,
                receiver: _peers[_hubEid],
                message: payload,
                options: bytes(""),
                payInLzToken: false
            });
        nativeFee = ILzEndpointLite(_endpoint)
            .quote(params, address(this))
            .nativeFee;
    }

    /// @inheritdoc ISpokeDepositGateway
    function peers(uint32 eid) external view returns (bytes32) {
        return _peers[eid];
    }

    /// @inheritdoc ISpokeDepositGateway
    function endpoint() external view returns (address) {
        return _endpoint;
    }

    /// @inheritdoc ISpokeDepositGateway
    function vault() external view returns (address) {
        return _vault;
    }

    /// @inheritdoc ISpokeDepositGateway
    function hubEid() external view returns (uint32) {
        return _hubEid;
    }
}

/// @notice Minimal recall surface added to `SpokeVaultStable` so that the
///         gateway can return BRIDGED escrow during a refund without taking
///         on the sweeper or payout roles.
interface ISpokeVaultStableRecall {
    function recallBridged(
        address asset,
        address to,
        uint256 amount
    ) external;
}
