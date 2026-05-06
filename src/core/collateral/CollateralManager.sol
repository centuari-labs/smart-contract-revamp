// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {ICollateralManager} from "../../interfaces/ICollateralManager.sol";
import {IBalanceLedger} from "../../interfaces/IBalanceLedger.sol";
import {IRiskModule} from "../../interfaces/IRiskModule.sol";
import {CollateralManagerStorage} from "./CollateralManagerStorage.sol";

/// @title CollateralManager
/// @notice Policy wrapper around BalanceLedger's collateral flag for mid-life
///         (non-settlement, non-repay) writes.
/// @dev Phase 1 design intent: BalanceLedger is the dumb accounting substrate,
///      and all policy (role gating, 24h flag-lock, RiskModule HF gate) lives
///      here or in `WithdrawalRegistry`. Concentrating policy in small, single-
///      purpose wrappers lets each layer evolve on its own upgrade path and
///      keeps BalanceLedger's storage layout stable.
///
///      The contract is deliberately minimal — a single operator role, a
///      single RiskModule pointer, a single uint64 flag-lock duration, and two
///      write entry points. Every other collateral mutation in Phase 1 goes
///      through either `Settlement._processMatch` (auto-flag at match) or
///      `Centuari.repay` (auto-unflag at repay-to-zero), neither of which
///      touches this contract.
contract CollateralManager is Initializable, OwnableUpgradeable, CollateralManagerStorage, ICollateralManager {
    // ============ Constants ============

    /// @notice Ceiling on `_flagLock` to prevent governance from bricking the
    ///         unflag path by setting an absurd duration
    /// @dev 30 days is >10x the default 24h — leaves headroom for policy
    ///      tuning without allowing a hostile or fat-fingered governance tx
    ///      to effectively disable mid-life unflagging.
    uint64 public constant MAX_FLAG_LOCK = 30 days;

    // ============ Constructor ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initializer ============

    /// @notice Initialize the CollateralManager
    /// @dev Can only be called once. Wires the BalanceLedger, RiskModule, and
    ///      operator pointers and seeds the flag-lock to 24 hours. Governance
    ///      is free to retune `_flagLock` after deployment.
    /// @param owner_ The governance owner (can swap RiskModule / operator / lock)
    /// @param operator_ The protocol settlement key allowed to flag/unflag
    /// @param balanceLedger_ The BalanceLedger instance this manager writes to
    /// @param riskModule_ The initial RiskModule policy pointer (stub in Phase 1)
    function initialize(address owner_, address operator_, address balanceLedger_, address riskModule_)
        external
        initializer
    {
        if (owner_ == address(0)) revert ZeroAddress();
        if (operator_ == address(0)) revert ZeroAddress();
        if (balanceLedger_ == address(0)) revert ZeroAddress();
        if (riskModule_ == address(0)) revert ZeroAddress();

        __Ownable_init(owner_);

        _balanceLedger = balanceLedger_;
        _riskModule = riskModule_;
        _operator = operator_;
        _flagLock = 24 hours;

        emit OperatorUpdated(address(0), operator_);
        emit RiskModuleUpdated(address(0), riskModule_);
        emit FlagLockUpdated(0, 24 hours);
    }

    // ============ Modifiers ============

    /// @notice Restricts function access to the current operator
    modifier onlyOperator() {
        if (msg.sender != _operator) revert NotOperator();
        _;
    }

    // ============ Operator actions ============

    /// @inheritdoc ICollateralManager
    function flagFor(address user, address asset) external onlyOperator {
        // No HF check: flagging strictly increases collateralization, it can
        // never push a user's HF below 1. BalanceLedger.markCollateral is
        // idempotent and will no-op if the pair is already flagged.
        IBalanceLedger(_balanceLedger).markCollateral(user, asset);
    }

    /// @inheritdoc ICollateralManager
    function unflagFor(address user, address asset) external onlyOperator {
        IBalanceLedger ledger = IBalanceLedger(_balanceLedger);

        uint64 fAt = ledger.flaggedAt(user, asset);
        if (fAt == 0) revert NotFlagged();

        uint64 unlocksAt = fAt + _flagLock;
        if (block.timestamp < unlocksAt) revert FlagLockActive(unlocksAt);

        if (!IRiskModule(_riskModule).canUnflag(user, asset)) {
            revert WouldMakeUnhealthy();
        }

        ledger.unmarkCollateral(user, asset);
    }

    // ============ Governance actions ============

    /// @inheritdoc ICollateralManager
    function setOperator(address newOperator) external onlyOwner {
        if (newOperator == address(0)) revert ZeroAddress();

        address oldOperator = _operator;
        _operator = newOperator;

        emit OperatorUpdated(oldOperator, newOperator);
    }

    /// @inheritdoc ICollateralManager
    function setRiskModule(address newRiskModule) external onlyOwner {
        if (newRiskModule == address(0)) revert ZeroAddress();

        address oldRiskModule = _riskModule;
        _riskModule = newRiskModule;

        emit RiskModuleUpdated(oldRiskModule, newRiskModule);
    }

    /// @inheritdoc ICollateralManager
    function setFlagLock(uint64 newFlagLock) external onlyOwner {
        if (newFlagLock > MAX_FLAG_LOCK) revert FlagLockTooLong();

        uint64 oldFlagLock = _flagLock;
        _flagLock = newFlagLock;

        emit FlagLockUpdated(oldFlagLock, newFlagLock);
    }

    // ============ Views ============

    /// @inheritdoc ICollateralManager
    function balanceLedger() external view returns (address) {
        return _balanceLedger;
    }

    /// @inheritdoc ICollateralManager
    function riskModule() external view returns (address) {
        return _riskModule;
    }

    /// @inheritdoc ICollateralManager
    function operator() external view returns (address) {
        return _operator;
    }

    /// @inheritdoc ICollateralManager
    function flagLock() external view returns (uint64) {
        return _flagLock;
    }
}
