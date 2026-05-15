// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ISpokeVaultStable} from "../../../interfaces/cross-chain/spoke/ISpokeVaultStable.sol";
import {SpokeVaultStableStorage} from "./SpokeVaultStableStorage.sol";
import {ReentrancyGuardUpgradeable} from "../../../utils/ReentrancyGuardUpgradeable.sol";

/// @notice Minimal CCTP v2 burn-side surface used by the vault. Mirrors
///         `TokenMessengerV2.depositForBurn` and `MockCCTPMessenger`.
interface ICctpTokenMessengerLite {
    function depositForBurn(uint256 amount, uint32 destinationDomain, bytes32 mintRecipient, address burnToken)
        external
        returns (uint64 nonce);
}

/// @notice Minimal Stargate V2 send-side surface. Field names mirror upstream
///         `IStargate` (`amountLD` / `minAmountLD` use Stargate's "Local
///         Decimals" convention) and are exempted from the mixedCase lint via
///         the per-line directives also used in `test/mocks/MockStargateRouter`.
interface IStargateLite {
    struct SendParam {
        uint32 dstEid;
        bytes32 to;
        // forge-lint: disable-next-line(mixed-case-variable)
        uint256 amountLD;
        // forge-lint: disable-next-line(mixed-case-variable)
        uint256 minAmountLD;
        bytes extraOptions;
        bytes composeMsg;
        bytes oftCmd;
    }

    struct MessagingFee {
        uint256 nativeFee;
        uint256 lzTokenFee;
    }

    function send(SendParam calldata params, MessagingFee calldata fee, address refundAddress)
        external
        payable
        returns (bytes32 guid, uint256 amountReceived);
}

/// @title SpokeVaultStable
/// @notice Dual-custody token vault on every spoke chain. Holds BRIDGED
///         tokens awaiting sweep to the hub and SPOKE_NATIVE tokens held in
///         permanent local custody.
/// @dev See `ISpokeVaultStable` for the full data flow. This contract has
///      three roles guarded by single-address modifiers: `_gateway` (inflows),
///      `_sweeper` (BRIDGED outflows), and `_payout` (SPOKE_NATIVE outflows).
///      All external state-mutating functions are `nonReentrant`.
contract SpokeVaultStable is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    SpokeVaultStableStorage,
    ISpokeVaultStable
{
    using SafeERC20 for IERC20;

    // ============ Constructor ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initializer ============

    /// @notice Initialise the vault. Roles can be wired later by the owner.
    /// @param owner_ Governance owner
    function initialize(address owner_) external initializer {
        if (owner_ == address(0)) revert ZeroAddress();

        __Ownable_init(owner_);
        __ReentrancyGuard_init();
    }

    // ============ Modifiers ============

    modifier onlyGateway() {
        if (msg.sender != _gateway) revert Unauthorized();
        _;
    }

    modifier onlySweeper() {
        if (msg.sender != _sweeper) revert Unauthorized();
        _;
    }

    modifier onlyPayout() {
        if (msg.sender != _payout) revert Unauthorized();
        _;
    }

    // ============ Gateway-only inflows ============

    /// @inheritdoc ISpokeVaultStable
    function depositBridged(address asset, address from, uint256 amount) external onlyGateway nonReentrant {
        if (asset == address(0)) revert ZeroAddress();
        if (from == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (_classifications[asset] != AssetClassification.BRIDGED) {
            revert UnsupportedAsset();
        }

        // The gateway has already pulled tokens from the user and approved
        // this vault for `amount`; pull them in.
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        _bridgedBalance[asset] += amount;

        emit BridgedDeposited(asset, from, amount);
    }

    /// @inheritdoc ISpokeVaultStable
    function depositSpokeNative(address asset, address from, uint256 amount) external onlyGateway nonReentrant {
        if (asset == address(0)) revert ZeroAddress();
        if (from == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (_classifications[asset] != AssetClassification.SPOKE_NATIVE) {
            revert UnsupportedAsset();
        }

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        _spokeNativeBalance[asset] += amount;

        emit SpokeNativeDeposited(asset, from, amount);
    }

    /// @inheritdoc ISpokeVaultStable
    function recallBridged(address asset, address to, uint256 amount) external onlyGateway nonReentrant {
        if (asset == address(0)) revert ZeroAddress();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (_classifications[asset] != AssetClassification.BRIDGED) {
            revert UnsupportedAsset();
        }

        uint256 available = _bridgedBalance[asset];
        if (available < amount) {
            revert InsufficientBridgedBalance(available, amount);
        }
        _bridgedBalance[asset] = available - amount;

        IERC20(asset).safeTransfer(to, amount);

        emit BridgedRecalled(asset, to, amount);
    }

    // ============ Sweeper-only outflows (BRIDGED) ============

    /// @inheritdoc ISpokeVaultStable
    function sweepCCTP(address asset, uint32 destinationDomain, bytes32 mintRecipient)
        external
        onlySweeper
        nonReentrant
        returns (uint256 amount, uint64 nonce)
    {
        if (asset == address(0)) revert ZeroAddress();
        AssetClassification cls = _classifications[asset];
        if (cls == AssetClassification.UNSUPPORTED) revert UnsupportedAsset();
        if (cls == AssetClassification.SPOKE_NATIVE) revert CannotSweepSpokeNative();
        if (_cctpMessenger == address(0)) revert CctpMessengerNotSet();

        amount = _bridgedBalance[asset];
        if (amount == 0) revert InsufficientBridgedBalance(0, 0);

        // Drain bookkeeping before the external call.
        _bridgedBalance[asset] = 0;

        IERC20(asset).forceApprove(_cctpMessenger, amount);
        nonce = ICctpTokenMessengerLite(_cctpMessenger).depositForBurn(amount, destinationDomain, mintRecipient, asset);

        emit SweptCCTP(asset, amount, destinationDomain, mintRecipient, nonce);
    }

    /// @inheritdoc ISpokeVaultStable
    function sweepStargate(address asset, uint32 dstEid, bytes32 to, uint256 minAmountOut, uint256 nativeFee)
        external
        payable
        onlySweeper
        nonReentrant
        returns (uint256 amountSent, uint256 amountReceived)
    {
        if (asset == address(0)) revert ZeroAddress();
        AssetClassification cls = _classifications[asset];
        if (cls == AssetClassification.UNSUPPORTED) revert UnsupportedAsset();
        if (cls == AssetClassification.SPOKE_NATIVE) revert CannotSweepSpokeNative();
        address router = _stargateRouter[asset];
        if (router == address(0)) revert StargateRouterNotSet(asset);

        amountSent = _bridgedBalance[asset];
        if (amountSent == 0) revert InsufficientBridgedBalance(0, 0);
        if (msg.value < nativeFee) {
            revert InsufficientLzFee(msg.value, nativeFee);
        }

        // Drain bookkeeping before the external call.
        _bridgedBalance[asset] = 0;

        IERC20(asset).forceApprove(router, amountSent);

        IStargateLite.SendParam memory params = IStargateLite.SendParam({
            dstEid: dstEid,
            to: to,
            amountLD: amountSent,
            minAmountLD: minAmountOut,
            extraOptions: bytes(""),
            composeMsg: bytes(""),
            oftCmd: bytes("")
        });
        IStargateLite.MessagingFee memory fee = IStargateLite.MessagingFee({nativeFee: nativeFee, lzTokenFee: 0});

        (, amountReceived) = IStargateLite(router).send{value: nativeFee}(params, fee, msg.sender);

        emit SweptStargate(asset, amountSent, dstEid, to, amountReceived);
    }

    /// @notice Internal helper to surface the same fee-mismatch error the
    ///         gateway uses, so external callers see one selector for the
    ///         "not enough native value" condition.
    error InsufficientLzFee(uint256 provided, uint256 required);

    // ============ Payout-only outflows (SPOKE_NATIVE) ============

    /// @inheritdoc ISpokeVaultStable
    function releaseSpokeNative(address asset, address to, uint256 amount) external onlyPayout nonReentrant {
        if (asset == address(0)) revert ZeroAddress();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        AssetClassification cls = _classifications[asset];
        if (cls == AssetClassification.UNSUPPORTED) revert UnsupportedAsset();
        if (cls == AssetClassification.BRIDGED) revert CannotReleaseBridged();

        uint256 available = _spokeNativeBalance[asset];
        if (available < amount) {
            revert InsufficientSpokeNativeBalance(available, amount);
        }
        _spokeNativeBalance[asset] = available - amount;

        IERC20(asset).safeTransfer(to, amount);

        emit SpokeNativeReleased(asset, to, amount);
    }

    // ============ Admin ============

    /// @inheritdoc ISpokeVaultStable
    function setAssetClassification(address asset, AssetClassification classification) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        _classifications[asset] = classification;
        emit AssetClassificationSet(asset, classification);
    }

    /// @inheritdoc ISpokeVaultStable
    function setStargateRouter(address asset, address router) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        _stargateRouter[asset] = router;
        emit StargateRouterSet(asset, router);
    }

    /// @inheritdoc ISpokeVaultStable
    function setCctpMessenger(address messenger) external onlyOwner {
        _cctpMessenger = messenger;
        emit CctpMessengerSet(messenger);
    }

    /// @inheritdoc ISpokeVaultStable
    function setGateway(address gateway_) external onlyOwner {
        _gateway = gateway_;
        emit GatewaySet(gateway_);
    }

    /// @inheritdoc ISpokeVaultStable
    function setSweeper(address sweeper_) external onlyOwner {
        _sweeper = sweeper_;
        emit SweeperSet(sweeper_);
    }

    /// @inheritdoc ISpokeVaultStable
    function setPayout(address payout_) external onlyOwner {
        _payout = payout_;
        emit PayoutSet(payout_);
    }

    // ============ Views ============

    /// @inheritdoc ISpokeVaultStable
    function bridgedBalance(address asset) external view returns (uint256) {
        return _bridgedBalance[asset];
    }

    /// @inheritdoc ISpokeVaultStable
    function spokeNativeBalance(address asset) external view returns (uint256) {
        return _spokeNativeBalance[asset];
    }

    /// @inheritdoc ISpokeVaultStable
    function classificationOf(address asset) external view returns (AssetClassification) {
        return _classifications[asset];
    }

    /// @inheritdoc ISpokeVaultStable
    function stargateRouterOf(address asset) external view returns (address) {
        return _stargateRouter[asset];
    }

    /// @inheritdoc ISpokeVaultStable
    function cctpMessenger() external view returns (address) {
        return _cctpMessenger;
    }

    /// @inheritdoc ISpokeVaultStable
    function gateway() external view returns (address) {
        return _gateway;
    }

    /// @inheritdoc ISpokeVaultStable
    function sweeper() external view returns (address) {
        return _sweeper;
    }

    /// @inheritdoc ISpokeVaultStable
    function payout() external view returns (address) {
        return _payout;
    }
}
