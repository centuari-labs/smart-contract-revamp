// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    IERC20
} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MockStargateRouter
/// @notice Minimal pool-bridge mock for Stargate V2. Stands in for the
///         `IStargate` entry point used by the Sweeper Bot (M7) when
///         bridging non-CCTP tokens (USDC on BNB, USDT, WETH, WBTC).
/// @dev Self-contained: does not import from the Stargate V2 package. Models
///      the fee, the transferFrom, and a captured send record. The actual
///      Stargate pool share accounting / rebalancer is not simulated — tests
///      that need full fidelity should pull from lib/stargate-v2 directly.
contract MockStargateRouter {
    using SafeERC20 for IERC20;

    // ============ Types ============

    struct SendParam {
        uint32 dstEid;
        bytes32 to;
        uint256 amountLD;
        uint256 minAmountLD;
        bytes extraOptions;
        bytes composeMsg;
        bytes oftCmd;
    }

    struct MessagingFee {
        uint256 nativeFee;
        uint256 lzTokenFee;
    }

    struct CapturedSend {
        address sender;
        address token;
        SendParam params;
        uint256 feePaid;
        uint256 amountReceivedAfterFee;
    }

    // ============ Storage ============

    /// @notice Underlying ERC20 this router bridges (one per mock instance).
    address public immutable token;

    /// @notice Basis-points pool fee (e.g. 6 = 0.06%). Default matches docs.
    uint256 public poolFeeBps;

    /// @notice Native messaging fee quoted by `quoteSend`.
    uint256 public nativeFee;

    CapturedSend[] private _sends;

    // ============ Events ============

    event OFTSent(
        bytes32 indexed guid,
        uint32 indexed dstEid,
        address indexed from,
        uint256 amountSentLD,
        uint256 amountReceivedLD
    );

    // ============ Errors ============

    error SlippageExceeded(uint256 received, uint256 minExpected);
    error InsufficientNativeFee(uint256 provided, uint256 required);
    error ZeroAmount();

    // ============ Constructor ============

    constructor(address token_) {
        token = token_;
        poolFeeBps = 6; // 0.06%
        nativeFee = 0.0001 ether;
    }

    // ============ Test Harness ============

    function setPoolFeeBps(uint256 bps) external {
        poolFeeBps = bps;
    }

    function setNativeFee(uint256 fee) external {
        nativeFee = fee;
    }

    function sendCount() external view returns (uint256) {
        return _sends.length;
    }

    function sendAt(
        uint256 index
    ) external view returns (CapturedSend memory) {
        return _sends[index];
    }

    // ============ Stargate-like Surface ============

    /// @notice Mirrors `IStargate.quoteSend`.
    function quoteSend(
        SendParam calldata /* params */,
        bool /* payInLzToken */
    ) external view returns (MessagingFee memory fee) {
        return MessagingFee({nativeFee: nativeFee, lzTokenFee: 0});
    }

    /// @notice Mirrors `IStargate.send`.
    function send(
        SendParam calldata params,
        MessagingFee calldata fee,
        address /* refundAddress */
    ) external payable returns (bytes32 guid, uint256 amountReceivedLD) {
        if (params.amountLD == 0) revert ZeroAmount();
        if (msg.value < fee.nativeFee) {
            revert InsufficientNativeFee(msg.value, fee.nativeFee);
        }

        IERC20(token).safeTransferFrom(
            msg.sender,
            address(this),
            params.amountLD
        );

        // Apply pool fee: received = amount * (10_000 - bps) / 10_000
        amountReceivedLD = (params.amountLD * (10_000 - poolFeeBps)) / 10_000;
        if (amountReceivedLD < params.minAmountLD) {
            revert SlippageExceeded(amountReceivedLD, params.minAmountLD);
        }

        guid = keccak256(
            abi.encodePacked(
                block.chainid,
                params.dstEid,
                msg.sender,
                params.to,
                params.amountLD,
                _sends.length
            )
        );

        _sends.push(
            CapturedSend({
                sender: msg.sender,
                token: token,
                params: params,
                feePaid: fee.nativeFee,
                amountReceivedAfterFee: amountReceivedLD
            })
        );

        emit OFTSent(
            guid,
            params.dstEid,
            msg.sender,
            params.amountLD,
            amountReceivedLD
        );
    }
}
