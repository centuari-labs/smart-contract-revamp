// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ICentuariRouter} from "../interfaces/ICentuariRouter.sol";

/// @title CentuariRouterStorage
abstract contract CentuariRouterStorage {
    /// @notice Intent storage
    mapping(bytes32 => ICentuariRouter.IntentDetails) internal _intents;

    /// @notice Per-caller nonce for intent ordering
    mapping(address => uint256) internal _callerNonce;

    /// @notice Undelivered CBT (callback failed)
    mapping(bytes32 => uint256) internal _undeliveredCBT;

    /// @notice Undelivered CBT token address
    mapping(bytes32 => address) internal _undeliveredCBTAddress;

    /// @notice Per-submitter intent IDs
    mapping(address => bytes32[]) internal _submitterIntents;

    /// @notice CentuariEndpoint address (Invariant #12: onlyEndpoint for onIntentFilled)
    address internal _endpoint;

    /// @notice CentuariRateOracle address
    address internal _rateOracle;

    /// @notice AssetBehaviorRegistry address
    address internal _assetBehaviorRegistry;

    /// @notice Minimum intent amount (anti-griefing)
    uint256 internal constant MIN_INTENT_AMOUNT = 100e6; // 100 USDC

    /// @notice Minimum deadline offset (5 minutes)
    uint256 internal constant MIN_DEADLINE_OFFSET = 5 minutes;

    /// @notice Gas limit for callback delivery
    uint256 internal constant CALLBACK_GAS_LIMIT = 200_000;

    /// @notice ERC-4626 vault state
    uint256 internal _totalManagedAssets;
    uint256 internal _totalShares;
    address internal _vaultAsset; // e.g., USDC

    /// @notice HIGH-3 FIX: Endpoint timelock vars
    address internal _pendingEndpoint;
    uint256 internal _pendingEndpointTimelockEnd;

    /// @notice Admin timelock duration
    uint256 internal constant ADMIN_TIMELOCK = 48 hours;

    /// @notice Pending admin address changes keyed by bytes32 identifier (48h timelock)
    mapping(bytes32 => address) internal _pendingAdminAddress;

    /// @notice Timelock end timestamps for pending admin address changes
    mapping(bytes32 => uint256) internal _pendingAdminTimelockEnd;

    // ============ Gap ============

    uint256[32] private __gap;
}
