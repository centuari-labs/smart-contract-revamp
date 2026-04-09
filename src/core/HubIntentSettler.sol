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

    // 48h timelock state for balanceLedger setter
    address public pendingBalanceLedger;
    uint256 public pendingBLTimelockEnd;

    // 48h timelock state for settlementLedger setter
    address public pendingSLedger;
    uint256 public pendingSLTimelockEnd;

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

        // P1-9 FIX: Use registerWithAsset (not register) so solver reimbursement can transfer tokens.
        // The old register() stored asset=address(0), making matchFill() skip the safeTransfer.
        if (settlementLedger != address(0)) {
            ISettlementLedger(settlementLedger).registerWithAsset(orderId, msg.sender, asset, amount);
        }

        emit SolverFillRegistered(orderId, msg.sender, user, asset, amount);
    }

    /// @notice Propose a new balanceLedger address with 48h timelock
    /// @param bl The new balanceLedger address
    function proposeBalanceLedger(address bl) external onlyOwner {
        if (bl == address(0)) revert ZeroAddress();
        pendingBalanceLedger = bl;
        pendingBLTimelockEnd = block.timestamp + 48 hours;
    }

    /// @notice Apply the pending balanceLedger change after the 48h timelock has elapsed
    function applyBalanceLedger() external onlyOwner {
        require(pendingBalanceLedger != address(0), "HubIntentSettler: no pending change");
        require(block.timestamp >= pendingBLTimelockEnd, "HubIntentSettler: timelock active");
        balanceLedger = pendingBalanceLedger;
        delete pendingBalanceLedger;
        delete pendingBLTimelockEnd;
    }

    /// @notice Cancel the pending balanceLedger change
    function cancelBalanceLedger() external onlyOwner {
        delete pendingBalanceLedger;
        delete pendingBLTimelockEnd;
    }

    /// @notice Propose a new settlementLedger address with 48h timelock
    /// @param sl The new settlementLedger address
    function proposeSettlementLedger(address sl) external onlyOwner {
        if (sl == address(0)) revert ZeroAddress();
        pendingSLedger = sl;
        pendingSLTimelockEnd = block.timestamp + 48 hours;
    }

    /// @notice Apply the pending settlementLedger change after the 48h timelock has elapsed
    function applySettlementLedger() external onlyOwner {
        require(pendingSLedger != address(0), "HubIntentSettler: no pending change");
        require(block.timestamp >= pendingSLTimelockEnd, "HubIntentSettler: timelock active");
        settlementLedger = pendingSLedger;
        delete pendingSLedger;
        delete pendingSLTimelockEnd;
    }

    /// @notice Cancel the pending settlementLedger change
    function cancelSettlementLedger() external onlyOwner {
        delete pendingSLedger;
        delete pendingSLTimelockEnd;
    }
}
