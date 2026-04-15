// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    IERC20
} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MockCCTPMessenger
/// @notice Minimal burn/mint mock for Circle CCTP v2. Stands in for both
///         `TokenMessengerV2` (burn side) and `MessageTransmitterV2` (mint
///         side) in unit tests covering the Sweeper Bot (M7) spoke -> hub
///         bridging path.
/// @dev Self-contained: does not import from the Circle CCTP package. When
///      PR 2 wires real sweeper logic, tests can keep this mock or migrate to
///      the real Circle local-fork harness under lib/evm-cctp-contracts.
contract MockCCTPMessenger {
    using SafeERC20 for IERC20;

    // ============ Types ============

    /// @notice A captured burn call.
    struct CapturedBurn {
        address burnToken;
        uint256 amount;
        uint32 destinationDomain;
        bytes32 mintRecipient;
        uint64 nonce;
    }

    // ============ Storage ============

    /// @notice Local CCTP "domain" id (e.g. Ethereum = 0, Base = 6).
    uint32 public immutable LOCAL_DOMAIN;

    /// @notice Next nonce returned by `depositForBurn`.
    uint64 public nextNonce;

    /// @notice burnToken -> total amount burnt (for assertions).
    mapping(address => uint256) public burntTotals;

    /// @notice Captured burns, ordered.
    CapturedBurn[] private _burns;

    // ============ Events ============

    event DepositForBurn(
        uint64 indexed nonce,
        address indexed burnToken,
        uint256 amount,
        address indexed depositor,
        bytes32 mintRecipient,
        uint32 destinationDomain
    );

    event MessageReceived(
        uint32 sourceDomain,
        uint64 nonce,
        bytes32 sender,
        bytes messageBody
    );

    // ============ Errors ============

    error ZeroAmount();
    error ZeroAddress();

    // ============ Constructor ============

    constructor(uint32 localDomain_) {
        LOCAL_DOMAIN = localDomain_;
    }

    // ============ Burn side (TokenMessengerV2-like) ============

    /// @notice Mock of `TokenMessengerV2.depositForBurn`.
    /// @dev Pulls tokens via `safeTransferFrom` and "burns" them by locking
    ///      them in this contract (the real CCTP burns via the TokenMinter).
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken
    ) external returns (uint64 nonce) {
        if (amount == 0) revert ZeroAmount();
        if (burnToken == address(0)) revert ZeroAddress();

        IERC20(burnToken).safeTransferFrom(msg.sender, address(this), amount);
        burntTotals[burnToken] += amount;

        unchecked {
            nextNonce += 1;
        }
        nonce = nextNonce;

        _burns.push(
            CapturedBurn({
                burnToken: burnToken,
                amount: amount,
                destinationDomain: destinationDomain,
                mintRecipient: mintRecipient,
                nonce: nonce
            })
        );

        emit DepositForBurn(
            nonce,
            burnToken,
            amount,
            msg.sender,
            mintRecipient,
            destinationDomain
        );
    }

    // ============ Mint side (MessageTransmitterV2-like) ============

    /// @notice Test helper: directly mint (transfer) pre-funded tokens to the
    ///         mint recipient to simulate `MessageTransmitterV2.receiveMessage`
    ///         + `TokenMinter.mint`.
    /// @dev The caller must have pre-funded this contract with the burn token.
    function mockReceiveAndMint(
        address token,
        address mintRecipient,
        uint256 amount,
        uint32 sourceDomain,
        uint64 nonce,
        bytes32 sender
    ) external {
        IERC20(token).safeTransfer(mintRecipient, amount);
        emit MessageReceived(
            sourceDomain,
            nonce,
            sender,
            abi.encode(token, mintRecipient, amount)
        );
    }

    // ============ Views ============

    function burnCount() external view returns (uint256) {
        return _burns.length;
    }

    function burnAt(
        uint256 index
    ) external view returns (CapturedBurn memory) {
        return _burns[index];
    }
}
