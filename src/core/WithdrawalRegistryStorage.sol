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

    uint256[44] private __gap;
}
