// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "../utils/ReentrancyGuardUpgradeable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IBalanceLedger} from "../interfaces/IBalanceLedger.sol";
import {BalanceLedger} from "./BalanceLedger.sol";

/// @title ProtocolTreasury
/// @notice Simple receiver contract for protocol fee revenue
/// @dev Receives fee credits via BalanceLedger.credit(). Multisig-controlled withdrawals.
///      Referral distributions are computed off-chain and distributed from this treasury.
contract ProtocolTreasury is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    // ============ Storage ============

    /// @notice BalanceLedger contract
    address internal _balanceLedger;

    /// @notice Admin timelock duration
    uint256 internal constant ADMIN_TIMELOCK = 48 hours;

    /// @notice Pending admin address changes keyed by bytes32 identifier (48h timelock)
    mapping(bytes32 => address) internal _pendingAdminAddress;

    /// @notice Timelock end timestamps for pending admin address changes
    mapping(bytes32 => uint256) internal _pendingAdminTimelockEnd;

    /// @dev Reserved storage for future upgrades
    uint256[46] private __gap;

    // ============ Events ============

    event FeesWithdrawn(address indexed asset, uint256 amount, address indexed to);
    event BalanceLedgerUpdated(address indexed oldLedger, address indexed newLedger);

    // ============ Errors ============

    error ZeroAddress();
    error ZeroAmount();

    // ============ Constructor ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initializer ============

    /// @param owner_ The owner address (multisig)
    /// @param balanceLedger_ The BalanceLedger contract
    function initialize(address owner_, address balanceLedger_) external initializer {
        if (owner_ == address(0) || balanceLedger_ == address(0)) revert ZeroAddress();

        __Ownable_init(owner_);
        __ReentrancyGuard_init();

        _balanceLedger = balanceLedger_;
    }

    // ============ Withdrawal ============

    /// @notice Withdraw accumulated fees from BalanceLedger to an external address
    /// @dev Calls BalanceLedger.withdraw() which transfers ERC20 tokens to this contract,
    ///      then forwards them to the target address.
    /// @param asset The token to withdraw
    /// @param amount The amount to withdraw
    /// @param to The recipient address
    function withdrawFees(address asset, uint256 amount, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        // BalanceLedger.withdraw() debits our available balance and transfers ERC20 to this contract
        BalanceLedger(_balanceLedger).withdraw(asset, amount);

        // Forward tokens to the target using SafeERC20
        SafeERC20.safeTransfer(IERC20(asset), to, amount);

        emit FeesWithdrawn(asset, amount, to);
    }

    // ============ Administrative ============

    /// @notice Propose a BalanceLedger change with 48h timelock.
    function proposeBalanceLedger(address ledger_) external onlyOwner {
        if (ledger_ == address(0)) revert ZeroAddress();
        bytes32 key = keccak256("balanceLedger");
        _pendingAdminAddress[key] = ledger_;
        _pendingAdminTimelockEnd[key] = block.timestamp + ADMIN_TIMELOCK;
    }

    function applyBalanceLedger() external onlyOwner {
        bytes32 key = keccak256("balanceLedger");
        require(_pendingAdminAddress[key] != address(0), "ProtocolTreasury: no pending ledger");
        require(block.timestamp >= _pendingAdminTimelockEnd[key], "ProtocolTreasury: timelock active");
        address old = _balanceLedger;
        _balanceLedger = _pendingAdminAddress[key];
        delete _pendingAdminAddress[key];
        delete _pendingAdminTimelockEnd[key];
        emit BalanceLedgerUpdated(old, _balanceLedger);
    }

    function cancelBalanceLedgerProposal() external onlyOwner {
        bytes32 key = keccak256("balanceLedger");
        delete _pendingAdminAddress[key];
        delete _pendingAdminTimelockEnd[key];
    }

    // ============ View ============

    function balanceLedger() external view returns (address) {
        return _balanceLedger;
    }
}
