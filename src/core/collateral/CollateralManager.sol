// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "../../utils/ReentrancyGuardUpgradeable.sol";

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
///      Two parallel entry-point families share one policy seam:
///        * Operator-gated (`flagFor` / `unflagFor`): the protocol settlement
///          key calls these on behalf of an arbitrary `user`. Used by
///          backend-v2's `POST /collateral/unflag` after the dequeue branch.
///        * Direct caller (`flag` / `unflag`): `msg.sender` flags or unflags
///          themselves. No operator gate. Used by the frontend's emergency
///          "Flag now" affordance (Phase 5) and forward-compatible with
///          Phase 6 `CentuariRouter`-style integrators that want to bypass
///          the backend entirely. Trustlessness invariant: a user can always
///          exit their own collateral position even if the backend is down.
///
///      Both families call the same internal `_flag` / `_unflag` helpers, so
///      the 24h flag-lock and `IRiskModule.canUnflag` gate cannot be bypassed
///      by picking a different entry point.
contract CollateralManager is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    CollateralManagerStorage,
    ICollateralManager
{
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
        __ReentrancyGuard_init();

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
    function flagFor(address user, address asset) external onlyOperator nonReentrant {
        _flag(user, asset);
    }

    /// @inheritdoc ICollateralManager
    function unflagFor(address user, address asset) external onlyOperator nonReentrant {
        _unflag(user, asset);
    }

    // ============ Direct-caller actions ============

    /// @inheritdoc ICollateralManager
    function flag(address asset) external nonReentrant {
        _flag(msg.sender, asset);
    }

    /// @inheritdoc ICollateralManager
    function unflag(address asset) external nonReentrant {
        _unflag(msg.sender, asset);
    }

    // ============ Internals ============

    /// @notice Mark `(user, asset)` as collateral on the BalanceLedger.
    /// @dev No HF check: flagging strictly increases collateralization, it can
    ///      never push a user's HF below 1. `BalanceLedger.markCollateral` is
    ///      idempotent and will no-op (without refreshing `_flaggedAt`) if the
    ///      pair is already flagged. Both entry points (operator + direct
    ///      caller) funnel through this helper so the policy is uniform.
    function _flag(address user, address asset) internal {
        IBalanceLedger(_balanceLedger).markCollateral(user, asset);
    }

    /// @notice Unmark `(user, asset)` as collateral on the BalanceLedger.
    /// @dev Enforces, in order: flag must exist, the 24-hour `_flagLock` must
    ///      have elapsed since the FIRST mark (`flaggedAt` is not refreshed by
    ///      idempotent re-marks), and `IRiskModule.canUnflag` must return true.
    ///      Reverts with the specific error on each failure so the backend can
    ///      map it to a distinct HTTP response code, and so direct callers see
    ///      the same diagnostics. Both entry points funnel through this helper
    ///      so the single-policy-seam invariant cannot be bypassed by picking
    ///      a different external function.
    function _unflag(address user, address asset) internal {
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
