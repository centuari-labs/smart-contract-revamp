// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MockLayerZeroEndpoint
/// @notice Simplified LayerZero V2 endpoint mock for cross-chain messaging tests
/// @dev Simulates send/receive without actual cross-chain communication.
///      Messages are queued and can be delivered manually in tests.
contract MockLayerZeroEndpoint {
    struct Message {
        uint32 dstEid;
        bytes message;
        address sender;
        uint64 nonce;
        bool delivered;
    }

    /// @notice Message queue
    Message[] public messages;

    /// @notice Per-destination nonce tracking
    mapping(uint32 => uint64) public nonces;

    /// @notice Registered receivers per chain (simulates OApp peer registration)
    mapping(uint32 => address) public peers;

    function setPeer(uint32 eid, address peer) external {
        peers[eid] = peer;
    }

    /// @notice Simulate sending a cross-chain message
    function send(
        uint32 dstEid,
        bytes calldata message,
        bytes calldata /*options*/
    ) external payable returns (uint64 nonce) {
        nonce = ++nonces[dstEid];
        messages.push(Message({
            dstEid: dstEid,
            message: message,
            sender: msg.sender,
            nonce: nonce,
            delivered: false
        }));
    }

    /// @notice Simulate delivering a message (called in tests to trigger lzReceive)
    /// @param messageIndex Index in the messages array
    /// @param receiver The contract to receive the message
    function deliver(uint256 messageIndex, address receiver) external {
        require(messageIndex < messages.length, "MockLZ: invalid index");
        Message storage m = messages[messageIndex];
        require(!m.delivered, "MockLZ: already delivered");

        m.delivered = true;

        // Call lzReceive on the receiver
        (bool success,) = receiver.call(
            abi.encodeWithSignature(
                "lzReceive(uint32,bytes32,bytes)",
                m.dstEid,
                bytes32(uint256(uint160(m.sender))),
                m.message
            )
        );
        require(success, "MockLZ: lzReceive failed");
    }

    /// @notice Get number of queued messages
    function messageCount() external view returns (uint256) {
        return messages.length;
    }

    /// @notice Quote fee (returns 0 in mock)
    function quote(uint32, bytes calldata, bytes calldata) external pure returns (uint256) {
        return 0;
    }
}
