// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MockLZEndpoint
/// @notice Minimal in-memory LayerZero V2 endpoint mock for unit tests.
/// @dev This mock is intentionally self-contained — it does not import from
///      the LayerZero V2 protocol package so that PR 1 can land before any
///      source file consumes the real endpoint. Later PRs (M5 spoke / hub
///      integration) can either keep using this mock or swap to the upstream
///      EndpointV2Mock from lib/layerzero-v2.
///
///      Supported surface (enough for M5 unit tests):
///
///      - `send(MessagingParams, address refundAddress)` — records the packet,
///        returns a deterministic `MessagingReceipt`, and can optionally
///        auto-deliver to the destination OApp when `_autoDeliver` is set.
///      - `quote(MessagingParams, address sender)` — returns a fixed fee.
///      - `setDestLzEndpoint(oapp, endpoint)` — wires the peer endpoint on the
///        destination chain (mocked as a second instance of this contract).
///      - `lzReceive(Origin, address receiver, bytes32 guid, bytes message,
///        bytes extraData)` — manually drives delivery to the receiver.
///
///      Real DVN verification, executor gas options, and native drop are
///      intentionally NOT modelled. Tests that need those should construct
///      a higher-fidelity harness.
contract MockLZEndpoint {
    // ============ Types ============

    /// @notice Mirrors `Origin` from LayerZero V2 `ILayerZeroEndpointV2`.
    struct Origin {
        uint32 srcEid;
        bytes32 sender;
        uint64 nonce;
    }

    /// @notice Mirrors `MessagingParams` from LayerZero V2 `ILayerZeroEndpointV2`.
    struct MessagingParams {
        uint32 dstEid;
        bytes32 receiver;
        bytes message;
        bytes options;
        bool payInLzToken;
    }

    /// @notice Mirrors `MessagingFee` from LayerZero V2 `ILayerZeroEndpointV2`.
    struct MessagingFee {
        uint256 nativeFee;
        uint256 lzTokenFee;
    }

    /// @notice Mirrors `MessagingReceipt` from LayerZero V2 `ILayerZeroEndpointV2`.
    struct MessagingReceipt {
        bytes32 guid;
        uint64 nonce;
        MessagingFee fee;
    }

    /// @notice A packet captured on the sending side.
    struct CapturedPacket {
        address sender;
        uint32 dstEid;
        bytes32 receiver;
        bytes message;
        bytes options;
        uint64 nonce;
        bytes32 guid;
    }

    // ============ Storage ============

    uint32 public immutable EID;
    uint256 public nativeFee;
    uint256 public lzTokenFee;
    bool public autoDeliver;

    uint64 private _outboundNonce;
    CapturedPacket[] private _packets;

    /// @notice dstEid => destination endpoint (for auto-delivery)
    mapping(uint32 => address) public destEndpoints;

    // ============ Events ============

    event PacketSent(
        address indexed sender,
        uint32 indexed dstEid,
        bytes32 indexed receiver,
        uint64 nonce,
        bytes32 guid,
        bytes message
    );

    event PacketDelivered(
        address indexed receiver, uint32 indexed srcEid, bytes32 indexed sender, uint64 nonce, bytes32 guid
    );

    // ============ Errors ============

    error InsufficientFee(uint256 provided, uint256 required);
    error NoDestEndpoint(uint32 dstEid);

    // ============ Constructor ============

    constructor(uint32 eid_) {
        EID = eid_;
        nativeFee = 0.0001 ether;
        lzTokenFee = 0;
    }

    // ============ Test Harness ============

    function setFee(uint256 nativeFee_, uint256 lzTokenFee_) external {
        nativeFee = nativeFee_;
        lzTokenFee = lzTokenFee_;
    }

    function setAutoDeliver(bool value) external {
        autoDeliver = value;
    }

    function setDestLzEndpoint(uint32 dstEid, address endpoint) external {
        destEndpoints[dstEid] = endpoint;
    }

    function packetCount() external view returns (uint256) {
        return _packets.length;
    }

    function packetAt(uint256 index) external view returns (CapturedPacket memory) {
        return _packets[index];
    }

    // ============ LZ-like Surface ============

    function quote(MessagingParams calldata, address) external view returns (MessagingFee memory) {
        return MessagingFee({nativeFee: nativeFee, lzTokenFee: lzTokenFee});
    }

    function send(MessagingParams calldata params, address) external payable returns (MessagingReceipt memory receipt) {
        if (msg.value < nativeFee) {
            revert InsufficientFee(msg.value, nativeFee);
        }

        unchecked {
            _outboundNonce += 1;
        }

        bytes32 guid = keccak256(
            abi.encodePacked(_outboundNonce, EID, msg.sender, params.dstEid, params.receiver, params.message)
        );

        _packets.push(
            CapturedPacket({
                sender: msg.sender,
                dstEid: params.dstEid,
                receiver: params.receiver,
                message: params.message,
                options: params.options,
                nonce: _outboundNonce,
                guid: guid
            })
        );

        receipt = MessagingReceipt({
            guid: guid, nonce: _outboundNonce, fee: MessagingFee({nativeFee: nativeFee, lzTokenFee: lzTokenFee})
        });

        emit PacketSent(msg.sender, params.dstEid, params.receiver, _outboundNonce, guid, params.message);

        if (autoDeliver) {
            _deliver(params.dstEid, msg.sender, params.receiver, params.message, _outboundNonce, guid);
        }
    }

    /// @notice Manually drive delivery to a receiver OApp.
    /// @dev Mirrors the signature of `OAppReceiver._lzReceive` well enough to
    ///      dispatch into a receiver that implements a `lzReceive(...)` entry.
    function deliver(
        uint32 dstEid,
        address sender,
        bytes32 receiver,
        bytes calldata message,
        uint64 nonce,
        bytes32 guid
    ) external {
        _deliver(dstEid, sender, receiver, message, nonce, guid);
    }

    // ============ Internal ============

    function _deliver(uint32 dstEid, address sender, bytes32 receiver, bytes memory message, uint64 nonce, bytes32 guid)
        internal
    {
        address destEndpoint = destEndpoints[dstEid];
        if (destEndpoint == address(0)) revert NoDestEndpoint(dstEid);

        address receiverAddr = _bytes32ToAddress(receiver);

        // Call through to `lzReceive(Origin, address, bytes32, bytes, bytes)`
        // — the canonical entry on `OAppReceiver`. The receiving OApp is
        // expected to trust `msg.sender == address(destEndpoint)`.
        Origin memory origin = Origin({srcEid: EID, sender: _addressToBytes32(sender), nonce: nonce});

        // LZ V2 standard signature: (Origin, bytes32 guid, bytes message, address executor, bytes extraData).
        (bool ok, bytes memory ret) = destEndpoint.call(
            abi.encodeWithSignature(
                "lzReceive((uint32,bytes32,uint64),bytes32,bytes,address,bytes)",
                origin,
                guid,
                message,
                receiverAddr,
                bytes("")
            )
        );
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }

        emit PacketDelivered(receiverAddr, EID, origin.sender, nonce, guid);
    }

    /// @notice Forwarding entry called by a peer endpoint's `_deliver`. Mirrors
    ///         the real `EndpointV2.lzReceive` which routes inbound packets to
    ///         the destination OApp. This endpoint becomes `msg.sender` so the
    ///         OApp's trust check (`msg.sender == _lzEndpoint`) passes.
    function lzReceive(
        Origin calldata origin,
        bytes32 guid,
        bytes calldata message,
        address receiver,
        bytes calldata extraData
    ) external {
        // LZ V2 standard signature: (Origin, bytes32 guid, bytes message, address executor, bytes extraData).
        (bool ok, bytes memory ret) = receiver.call(
            abi.encodeWithSignature(
                "lzReceive((uint32,bytes32,uint64),bytes32,bytes,address,bytes)",
                origin,
                guid,
                message,
                receiver,
                extraData
            )
        );
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    function _bytes32ToAddress(bytes32 value) internal pure returns (address) {
        return address(uint160(uint256(value)));
    }

    function _addressToBytes32(address value) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(value)));
    }
}
