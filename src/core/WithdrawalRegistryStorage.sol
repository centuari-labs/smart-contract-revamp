// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IWithdrawalRegistry} from "../interfaces/IWithdrawalRegistry.sol";

/// @title WithdrawalRegistryStorage
abstract contract WithdrawalRegistryStorage {
    mapping(bytes32 => IWithdrawalRegistry.WithdrawalRequest) internal _requests;
    mapping(bytes32 => bool) internal _authorized;
    address internal _balanceLedger;
    address internal _yieldRouter;
    mapping(address => bool) internal _authorizedCallers;
    uint256 internal constant _MAX_WITHDRAWAL_QUEUE_HOURS = 4;
    uint256 internal _requestCounter;

    /// @notice Pending admin address changes keyed by bytes32 identifier (48h timelock)
    mapping(bytes32 => address) internal _pendingAdminAddress;

    /// @notice Timelock end timestamps for pending admin address changes
    mapping(bytes32 => uint256) internal _pendingAdminTimelockEnd;

    /// @notice Pending authorized-caller bool keyed by caller address (48h timelock)
    mapping(address => bool) internal _pendingAdminBool;

    uint256[41] private __gap;
}
