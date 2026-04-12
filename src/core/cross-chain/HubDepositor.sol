// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    Initializable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {
    IERC20
} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IHubDepositor} from "../../interfaces/cross-chain/IHubDepositor.sol";
import {IBalanceLedger} from "../../interfaces/IBalanceLedger.sol";
import {HubDepositorStorage} from "./HubDepositorStorage.sol";
import {ReentrancyGuardUpgradeable} from "../../utils/ReentrancyGuardUpgradeable.sol";

/// @title HubDepositor
/// @notice Hub-native (Arbitrum) entry point for direct deposit and withdrawal.
/// @dev Users on the hub chain call `deposit` to lock ERC20 tokens in this
///      contract and credit their `BalanceLedger.available`. No solver, no
///      bridge, no LayerZero — single-tx, same-chain. `payout` releases tokens
///      back to the user (hub-native withdrawal path, called by
///      WithdrawalRegistry in M4; onlyOwner in M3).
///
///      Token custody: this contract holds the actual ERC20 tokens deposited
///      on the hub chain.
contract HubDepositor is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    HubDepositorStorage,
    IHubDepositor
{
    using SafeERC20 for IERC20;

    // ============ Constructor ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initializer ============

    /// @notice Initialize the HubDepositor
    /// @dev Can only be called once. Wires the BalanceLedger pointer.
    ///      HubDepositor must be registered as an authorized writer on
    ///      BalanceLedger before any deposit can succeed.
    /// @param owner_ The governance owner
    /// @param balanceLedger_ The BalanceLedger instance this depositor writes to
    function initialize(
        address owner_,
        address balanceLedger_
    ) external initializer {
        if (owner_ == address(0)) revert ZeroAddress();
        if (balanceLedger_ == address(0)) revert ZeroAddress();

        __Ownable_init(owner_);
        __ReentrancyGuard_init();

        _balanceLedger = balanceLedger_;
    }

    // ============ User actions ============

    /// @inheritdoc IHubDepositor
    function deposit(address asset, uint256 amount) external nonReentrant {
        if (asset == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        // Pull tokens from the caller into this contract
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        // Credit the caller's available balance on the ledger
        IBalanceLedger(_balanceLedger).credit(msg.sender, asset, amount);

        emit Deposited(msg.sender, asset, amount);
    }

    // ============ Authorized actions ============

    /// @inheritdoc IHubDepositor
    function payout(
        address user,
        address asset,
        uint256 amount
    ) external onlyOwner nonReentrant {
        if (user == address(0)) revert ZeroAddress();
        if (asset == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        // Debit the user's available balance on the ledger
        IBalanceLedger(_balanceLedger).debit(user, asset, amount);

        // Release tokens to the user
        IERC20(asset).safeTransfer(user, amount);

        emit PayoutReleased(user, asset, amount);
    }

    // ============ Views ============

    /// @inheritdoc IHubDepositor
    function balanceLedger() external view returns (address) {
        return _balanceLedger;
    }
}
