// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISpokePayout} from "../../../interfaces/cross-chain/spoke/ISpokePayout.sol";

/// @title SpokePayoutStorage
/// @notice Storage layout for the upgradeable SpokePayout contract.
/// @dev IMPORTANT: Only append new storage variables to the end.
abstract contract SpokePayoutStorage {
    // ============ LZ wiring ============

    /// @notice LayerZero V2 endpoint on this spoke chain.
    address internal _lzEndpoint;

    /// @notice eid → trusted hub peer as bytes32.
    mapping(uint32 => bytes32) internal _peers;

    // ============ External pointers ============

    /// @notice SpokeVaultStable for SPOKE_NATIVE releases.
    address internal _vault;

    /// @notice Address allowed to replenish the bridged buffer.
    address internal _sweeper;

    // ============ Bridged buffer ============

    /// @notice ERC20 balance available for immediate BRIDGED payouts.
    mapping(address => uint256) internal _bridgedBuffer;

    // ============ Pending payout queue ============

    /// @notice (user, asset) → ordered list of queued BRIDGED payouts.
    mapping(address => mapping(address => ISpokePayout.PendingPayout[]))
        internal _pendingPayouts;

    // ============ Storage Gap ============

    /// @notice Storage gap for future upgrades.
    /// @dev 6 slots consumed, leaving 44 from the 50-slot budget.
    uint256[44] private __gap;
}
