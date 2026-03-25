// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IHubIntentSettler} from "../interfaces/IHubIntentSettler.sol";
import {IBalanceLedger} from "../interfaces/IBalanceLedger.sol";
import {ISettlementLedger} from "../interfaces/ISettlementLedger.sol";

/// @title HubIntentSettler
/// @notice ERC-7683 hub side — credits BalanceLedger when solver fills a deposit intent
/// @dev Security Invariant #6: fillFor() requires actual token transfer from solver
///      before crediting BalanceLedger. Verified via balanceOf check.
contract HubIntentSettler is IHubIntentSettler, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public balanceLedger;
    address public settlementLedger;
    mapping(address => bool) public authorizedSolvers;

    constructor(address owner_) Ownable(owner_) {}

    /// @inheritdoc IHubIntentSettler
    function fillFor(
        bytes32 orderId,
        address user,
        address asset,
        uint256 amount
    ) external override nonReentrant {
        if (user == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        // Security Invariant #6: verify actual token transfer
        uint256 balBefore = IERC20(asset).balanceOf(address(this));
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        uint256 balAfter = IERC20(asset).balanceOf(address(this));

        uint256 received = balAfter - balBefore;
        if (received < amount) revert InsufficientTransfer(amount, received);

        // Credit BalanceLedger
        IBalanceLedger(balanceLedger).credit(user, asset, amount);

        // 1D FIX: Register solver fill for async reimbursement tracking (arch §6.4.1)
        if (settlementLedger != address(0)) {
            ISettlementLedger(settlementLedger).register(orderId, msg.sender, amount);
        }

        emit SolverFillRegistered(orderId, msg.sender, user, asset, amount);
    }

    function setBalanceLedger(address bl) external onlyOwner { balanceLedger = bl; }
    function setSettlementLedger(address sl) external onlyOwner { settlementLedger = sl; }
}
