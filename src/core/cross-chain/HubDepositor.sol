// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IHubDepositor} from "../../interfaces/cross-chain/IHubDepositor.sol";
import {IBalanceLedger} from "../../interfaces/IBalanceLedger.sol";
import {HubDepositorStorage} from "./HubDepositorStorage.sol";
import {ReentrancyGuardUpgradeable} from "../../utils/ReentrancyGuardUpgradeable.sol";

/// @title HubDepositor
/// @notice Hub-native (Arbitrum) entry point for direct deposit and withdrawal.
/// @dev Users on the hub chain call `deposit` to lock ERC20 tokens in this
///      contract and credit their `BalanceLedger.available`. No solver, no
///      bridge, no LayerZero — single-tx, same-chain. `payoutDirect` releases
///      tokens back to the user on the hub-native withdrawal path, called by
///      WithdrawalRegistry after its on-chain HF gate has already debited the
///      ledger.
///
///      The gate-bypassing `payout` (debit + transfer in one authorized call)
///      was permanently removed in Track C6 — every withdrawal now flows through
///      `WithdrawalRegistry.requestWithdrawalFor`.
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
    function initialize(address owner_, address balanceLedger_) external initializer {
        if (owner_ == address(0)) revert ZeroAddress();
        if (balanceLedger_ == address(0)) revert ZeroAddress();

        __Ownable_init(owner_);
        __ReentrancyGuard_init();

        _balanceLedger = balanceLedger_;
    }

    // ============ Modifiers ============

    /// @notice Restricts access to the owner or authorized callers
    modifier onlyAuthorized() {
        if (msg.sender != owner() && !_authorizedCallers[msg.sender]) {
            revert Unauthorized();
        }
        _;
    }

    // ============ User actions ============

    /// @inheritdoc IHubDepositor
    function deposit(address asset, uint256 amount) external nonReentrant {
        if (asset == address(0)) revert ZeroAddress();
        if (!_supportedAssets[asset]) revert UnsupportedAsset();
        if (amount == 0) revert ZeroAmount();

        // Pull tokens from the caller into this contract
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        // Credit the caller's available balance on the ledger
        IBalanceLedger(_balanceLedger).credit(msg.sender, asset, amount);

        emit Deposited(msg.sender, asset, amount);
    }

    // ============ Authorized actions ============

    /// @inheritdoc IHubDepositor
    function payoutDirect(address user, address asset, uint256 amount) external onlyAuthorized nonReentrant {
        if (user == address(0)) revert ZeroAddress();
        if (asset == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        // Release tokens WITHOUT debiting BalanceLedger.
        // Used by WithdrawalRegistry for hub-native withdrawals where the
        // debit was already performed in requestWithdrawal().
        IERC20(asset).safeTransfer(user, amount);

        emit PayoutReleased(user, asset, amount);
    }

    // ============ Authorized caller management ============

    /// @inheritdoc IHubDepositor
    function setAuthorizedCaller(address caller, bool authorized) external onlyOwner {
        if (caller == address(0)) revert ZeroAddress();
        _authorizedCallers[caller] = authorized;
        emit AuthorizedCallerUpdated(caller, authorized);
    }

    // ============ Asset management ============

    /// @inheritdoc IHubDepositor
    function addSupportedAsset(address asset) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        _supportedAssets[asset] = true;
        emit AssetAdded(asset);
    }

    /// @inheritdoc IHubDepositor
    function removeSupportedAsset(address asset) external onlyOwner {
        _supportedAssets[asset] = false;
        emit AssetRemoved(asset);
    }

    // ============ Views ============

    /// @inheritdoc IHubDepositor
    function balanceLedger() external view returns (address) {
        return _balanceLedger;
    }

    /// @inheritdoc IHubDepositor
    function isSupportedAsset(address asset) external view returns (bool) {
        return _supportedAssets[asset];
    }

    /// @inheritdoc IHubDepositor
    function isAuthorizedCaller(address caller) external view returns (bool) {
        return _authorizedCallers[caller];
    }
}
