// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {ISettlementLedger} from "../../interfaces/cross-chain/ISettlementLedger.sol";
import {IHubIntentSettler} from "../../interfaces/cross-chain/IHubIntentSettler.sol";
import {SettlementLedgerStorage} from "./SettlementLedgerStorage.sol";
import {ReentrancyGuardUpgradeable} from "../../utils/ReentrancyGuardUpgradeable.sol";

/// @title SettlementLedger
/// @notice Tracks solver reimbursement obligations for cross-chain deposits.
/// @dev Pure accounting contract — does NOT hold tokens. When the Sweeper Bot
///      calls `matchAndReimburse`, this contract calls
///      `HubIntentSettler.releaseToSolver` to transfer tokens from the settler's
///      custody to the solver's EOA.
///
///      State machine per depositId: NONE → REGISTERED → REIMBURSED.
contract SettlementLedger is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    SettlementLedgerStorage,
    ISettlementLedger
{
    // ============ Constructor ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initializer ============

    /// @notice Initialize the SettlementLedger
    /// @param owner_ The governance owner
    /// @param operator_ The Sweeper Bot operator
    /// @param hubIntentSettler_ The HubIntentSettler that calls register()
    function initialize(address owner_, address operator_, address hubIntentSettler_) external initializer {
        if (owner_ == address(0)) revert ZeroAddress();
        if (operator_ == address(0)) revert ZeroAddress();
        if (hubIntentSettler_ == address(0)) revert ZeroAddress();

        __Ownable_init(owner_);
        __ReentrancyGuard_init();

        _operator = operator_;
        _hubIntentSettler = hubIntentSettler_;

        emit OperatorUpdated(address(0), operator_);
        emit HubIntentSettlerUpdated(address(0), hubIntentSettler_);
    }

    // ============ Modifiers ============

    /// @notice Restricts access to the operator (Sweeper Bot)
    modifier onlyOperator() {
        if (msg.sender != _operator) revert Unauthorized();
        _;
    }

    /// @notice Restricts access to the HubIntentSettler
    modifier onlyHubIntentSettler() {
        if (msg.sender != _hubIntentSettler) revert Unauthorized();
        _;
    }

    // ============ HubIntentSettler Actions ============

    /// @inheritdoc ISettlementLedger
    function register(bytes32 depositId, address solver, address asset, uint256 amount) external onlyHubIntentSettler {
        if (solver == address(0)) revert ZeroAddress();
        if (asset == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        ReimbursementRecord storage record = _records[depositId];
        if (record.status != ReimbursementStatus.NONE) {
            revert AlreadyRegistered(depositId);
        }

        record.solver = solver;
        record.asset = asset;
        record.amount = amount;
        record.status = ReimbursementStatus.REGISTERED;

        emit ReimbursementRegistered(depositId, solver, asset, amount);
    }

    // ============ Operator Actions ============

    /// @inheritdoc ISettlementLedger
    function matchAndReimburse(bytes32 depositId) external onlyOperator nonReentrant {
        ReimbursementRecord storage record = _records[depositId];

        if (record.status != ReimbursementStatus.REGISTERED) {
            revert InvalidStatus(depositId, record.status);
        }

        record.status = ReimbursementStatus.REIMBURSED;

        // Release tokens from HubIntentSettler to the solver's EOA
        IHubIntentSettler(_hubIntentSettler).releaseToSolver(record.solver, record.asset, record.amount);

        emit ReimbursementCompleted(depositId, record.solver, record.asset, record.amount);
    }

    // ============ Governance ============

    /// @notice Update the operator address
    /// @param newOperator The new Sweeper Bot operator
    function setOperator(address newOperator) external onlyOwner {
        if (newOperator == address(0)) revert ZeroAddress();

        address oldOperator = _operator;
        _operator = newOperator;

        emit OperatorUpdated(oldOperator, newOperator);
    }

    /// @notice Update the HubIntentSettler pointer
    /// @param newHubIntentSettler The new HubIntentSettler address
    function setHubIntentSettler(address newHubIntentSettler) external onlyOwner {
        if (newHubIntentSettler == address(0)) revert ZeroAddress();

        address oldHubIntentSettler = _hubIntentSettler;
        _hubIntentSettler = newHubIntentSettler;

        emit HubIntentSettlerUpdated(oldHubIntentSettler, newHubIntentSettler);
    }

    // ============ Views ============

    /// @inheritdoc ISettlementLedger
    function getRecord(bytes32 depositId) external view returns (ReimbursementRecord memory) {
        return _records[depositId];
    }

    /// @inheritdoc ISettlementLedger
    function hubIntentSettler() external view returns (address) {
        return _hubIntentSettler;
    }

    /// @inheritdoc ISettlementLedger
    function operator() external view returns (address) {
        return _operator;
    }
}
