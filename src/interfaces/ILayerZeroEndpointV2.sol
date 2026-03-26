// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ILayerZeroEndpointV2 — Minimal interface for Centuari cross-chain messaging
/// @notice Production LayerZero V2 endpoint interface. Only the functions Centuari needs.
/// @dev Full spec: https://docs.layerzero.network/v2/developers/evm/protocol-gas-settings/options
///      The actual LayerZero endpoint contract is deployed by LayerZero Labs on each chain.
///      Centuari contracts call this interface to send cross-chain messages.
interface ILayerZeroEndpointV2 {
    /// @notice MessagingParams for lzSend
    struct MessagingParams {
        uint32 dstEid;           // destination endpoint ID (chain identifier)
        bytes32 receiver;        // destination OApp address as bytes32
        bytes message;           // encoded message payload
        bytes options;           // execution options (gas, value)
        bool payInLzToken;       // pay fees in LZ token instead of native
    }

    /// @notice MessagingReceipt returned by send()
    struct MessagingReceipt {
        bytes32 guid;            // global unique identifier for the message
        uint64 nonce;            // message nonce
        MessagingFee fee;        // actual fee charged
    }

    /// @notice MessagingFee struct
    struct MessagingFee {
        uint256 nativeFee;       // fee in native token (ETH)
        uint256 lzTokenFee;      // fee in LZ token
    }

    /// @notice Send a cross-chain message
    /// @param _params The messaging parameters
    /// @param _refundAddress Address to refund excess fees
    /// @return receipt The messaging receipt with GUID and nonce
    function send(
        MessagingParams calldata _params,
        address _refundAddress
    ) external payable returns (MessagingReceipt memory receipt);

    /// @notice Quote the fee for sending a message
    /// @param _params The messaging parameters
    /// @param _sender The sender address for fee calculation
    /// @return fee The quoted fee
    function quote(
        MessagingParams calldata _params,
        address _sender
    ) external view returns (MessagingFee memory fee);
}
