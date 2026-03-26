// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ISettlementLedger} from "../interfaces/ISettlementLedger.sol";

/// @title SettlementLedger
/// @notice Async solver reimbursement tracking
/// @dev Records solver fills. When Sweeper bridges tokens, matches against pending fills.
contract SettlementLedger is ISettlementLedger, Ownable {
    struct PendingFill {
        address solver;
        uint256 amount;
        bool matched;
    }

    mapping(bytes32 => PendingFill) internal _fills;
    mapping(address => bool) internal _authorizedCallers;

    /// @notice Admin timelock duration
    uint256 internal constant ADMIN_TIMELOCK = 48 hours;

    /// @notice Pending admin address changes keyed by bytes32 identifier (48h timelock)
    mapping(bytes32 => address) internal _pendingAdminAddress;

    /// @notice Timelock end timestamps for pending admin address changes
    mapping(bytes32 => uint256) internal _pendingAdminTimelockEnd;

    /// @notice Pending authorized-caller bool keyed by caller address (48h timelock)
    mapping(address => bool) internal _pendingAdminBool;

    constructor(address owner_) Ownable(owner_) {}

    modifier onlyAuthorized() {
        if (!_authorizedCallers[msg.sender]) revert Unauthorized();
        _;
    }

    /// @inheritdoc ISettlementLedger
    function register(bytes32 orderId, address solver, uint256 amount) external override onlyAuthorized {
        if (_fills[orderId].solver != address(0)) revert OrderAlreadyRegistered(orderId);
        _fills[orderId] = PendingFill({solver: solver, amount: amount, matched: false});
        emit FillRegistered(orderId, solver, amount);
    }

    /// @inheritdoc ISettlementLedger
    function matchFill(bytes32 orderId, uint256 bridgedAmount) external override onlyAuthorized {
        PendingFill storage fill = _fills[orderId];
        if (fill.solver == address(0)) revert OrderNotFound(orderId);
        if (fill.matched) revert OrderNotFound(orderId);

        fill.matched = true;
        emit FillMatched(orderId, fill.solver, bridgedAmount);
    }

    /// @inheritdoc ISettlementLedger
    function isPending(bytes32 orderId) external view override returns (bool) {
        return _fills[orderId].solver != address(0) && !_fills[orderId].matched;
    }

    /// @inheritdoc ISettlementLedger
    function getPendingFill(bytes32 orderId) external view override returns (address, uint256) {
        PendingFill storage fill = _fills[orderId];
        return (fill.solver, fill.amount);
    }

    /// @notice Propose an authorized-caller change with 48h timelock.
    function proposeAuthorizedCaller(address caller, bool authorized) external onlyOwner {
        if (caller == address(0)) revert Unauthorized();
        bytes32 key = bytes32(uint256(uint160(caller)));
        _pendingAdminAddress[key] = caller;
        _pendingAdminTimelockEnd[key] = block.timestamp + ADMIN_TIMELOCK;
        _pendingAdminBool[caller] = authorized;
    }

    function applyAuthorizedCaller(address caller) external onlyOwner {
        bytes32 key = bytes32(uint256(uint160(caller)));
        require(_pendingAdminAddress[key] != address(0), "SettlementLedger: no pending caller");
        require(block.timestamp >= _pendingAdminTimelockEnd[key], "SettlementLedger: timelock active");
        _authorizedCallers[caller] = _pendingAdminBool[caller];
        delete _pendingAdminAddress[key];
        delete _pendingAdminTimelockEnd[key];
        delete _pendingAdminBool[caller];
    }

    function cancelAuthorizedCallerChange(address caller) external onlyOwner {
        bytes32 key = bytes32(uint256(uint160(caller)));
        delete _pendingAdminAddress[key];
        delete _pendingAdminTimelockEnd[key];
        delete _pendingAdminBool[caller];
    }
}
