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

    function setAuthorizedCaller(address caller, bool authorized) external onlyOwner {
        _authorizedCallers[caller] = authorized;
    }
}
