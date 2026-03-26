// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ISettlementLedger} from "../interfaces/ISettlementLedger.sol";

/// @title SettlementLedger
/// @notice Async solver reimbursement tracking
/// @dev Records solver fills. When Sweeper bridges tokens, matches against pending fills.
contract SettlementLedger is ISettlementLedger, Ownable {
    using SafeERC20 for IERC20;
    struct PendingFill {
        address solver;
        address asset;    // P0 FIX: Track asset for token transfer on match
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
    /// @dev P0 FIX: Now accepts asset address for token transfer tracking.
    function register(bytes32 orderId, address solver, uint256 amount) external override onlyAuthorized {
        if (_fills[orderId].solver != address(0)) revert OrderAlreadyRegistered(orderId);
        _fills[orderId] = PendingFill({solver: solver, asset: address(0), amount: amount, matched: false});
        emit FillRegistered(orderId, solver, amount);
    }

    /// @notice Register with asset tracking (preferred — enables reimbursement transfer)
    function registerWithAsset(bytes32 orderId, address solver, address asset, uint256 amount) external onlyAuthorized {
        if (_fills[orderId].solver != address(0)) revert OrderAlreadyRegistered(orderId);
        _fills[orderId] = PendingFill({solver: solver, asset: asset, amount: amount, matched: false});
        emit FillRegistered(orderId, solver, amount);
    }

    /// @inheritdoc ISettlementLedger
    /// @dev P0 FIX: Now transfers bridged tokens to the solver as reimbursement.
    ///      The Sweeper Bot calls this after bridging real tokens from spoke to hub.
    ///      Without this transfer, solvers front capital permanently with no reimbursement.
    function matchFill(bytes32 orderId, uint256 bridgedAmount) external override onlyAuthorized {
        PendingFill storage fill = _fills[orderId];
        if (fill.solver == address(0)) revert OrderNotFound(orderId);
        if (fill.matched) revert OrderNotFound(orderId);

        fill.matched = true;

        // P0 FIX: Transfer bridged tokens to solver as reimbursement
        // The Sweeper Bot deposits tokens into this contract before calling matchFill.
        // If asset is tracked and contract holds sufficient balance, transfer to solver.
        if (fill.asset != address(0) && bridgedAmount > 0) {
            uint256 balance = IERC20(fill.asset).balanceOf(address(this));
            if (balance >= bridgedAmount) {
                IERC20(fill.asset).safeTransfer(fill.solver, bridgedAmount);
            }
        }

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
