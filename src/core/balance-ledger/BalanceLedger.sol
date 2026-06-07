// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IBalanceLedger} from "../../interfaces/IBalanceLedger.sol";
import {BalanceLedgerStorage} from "./BalanceLedgerStorage.sol";

/// @title BalanceLedger
/// @notice On-chain source of truth for per-user, per-asset balances across
///         three sub-states: `available`, `inOrders`, `inYieldRouter`.
/// @dev BalanceLedger is pure accounting — it NEVER holds tokens. Authorized
///      writers (Centuari, HubDepositor, WithdrawalRegistry, HubIntentSettler,
///      and later CentuariEndpoint / YieldRouter / LiquidationEngine) are
///      responsible for the actual token custody. This contract only keeps
///      the books.
///
///      Phase 1 entry points only write `available` (via credit/debit). The
///      `inOrders` and `inYieldRouter` storage fields exist for forward
///      compatibility with Phase 6 (CentuariRouter) and Phase 5B (YieldRouter)
///      and always read as zero in Phase 1.
///
///      Collateral is HF-gated virtual (Aave/Compound pattern): a borrow locks
///      no balance. An on-chain `usedAsCollateral` flag (+ `_flaggedAt`) IS kept
///      here per (user, asset) and is written ONLY by authorized writers via
///      `markCollateral` / `unmarkCollateral`. The flag write seam is shared with
///      credit/debit (a single `onlyAuthorizedWriter` gate), so the safety of the
///      collateral model depends on the authorized-writer set being exactly the
///      intended contracts — see `script/VerifyBalanceLedgerWriters.s.sol`, which
///      asserts that set post-deploy. Flag lifecycle: `Settlement`→`Centuari.settleMatch`
///      auto-flags requested collateral; `Centuari.repay` does NOT touch flags;
///      `CollateralManager.unflagFor` is the user-facing unflag seam (24h flag-lock
///      + `IRiskModule.canUnflag`); `LiquidationEngine` auto-unmarks on full drain.
///
///      Deployed behind an ERC1967 transparent proxy for upgradeability.
contract BalanceLedger is Initializable, OwnableUpgradeable, BalanceLedgerStorage, IBalanceLedger {
    using EnumerableSet for EnumerableSet.AddressSet;

    // ============ Constructor ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initializer ============

    /// @notice Initialize the BalanceLedger contract
    /// @dev Can only be called once. Sets the owner and the force-writer-registration flag.
    ///      The initial authorized writer set is empty; writers are added by the owner
    ///      via proposeAuthorizedWriter + executeAuthorizedWriter (48h timelock), or
    ///      via forceAddWriter if force-registration was enabled at init time.
    /// @param owner_ The owner address (can manage writers and pause)
    /// @param forceWriterRegistrationEnabled_ Whether forceAddWriter is permitted on this instance.
    ///        MUST be false in mainnet production deployments.
    function initialize(address owner_, bool forceWriterRegistrationEnabled_) external initializer {
        if (owner_ == address(0)) revert ZeroAddress();

        __Ownable_init(owner_);

        _forceWriterRegistrationEnabled = forceWriterRegistrationEnabled_;
        _paused = false;
        _pauser = owner_;
    }

    // ============ Events ============

    /// @notice Emitted when the guardian (pauser) address is rotated
    event PauserUpdated(address indexed oldPauser, address indexed newPauser);

    // ============ Modifiers ============

    /// @notice Restricts function access to addresses currently in the authorized writer set
    modifier onlyAuthorizedWriter() {
        if (!_authorizedWriters[msg.sender]) revert Unauthorized();
        _;
    }

    /// @notice Ensures the contract is not paused
    modifier whenNotPaused() {
        if (_paused) revert ContractPaused();
        _;
    }

    /// @notice Restricts pause/unpause to the guardian (fast emergency path, no timelock)
    modifier onlyPauser() {
        if (msg.sender != _pauser) revert Unauthorized();
        _;
    }

    // ============ Balance Mutators ============

    /// @inheritdoc IBalanceLedger
    function credit(address user, address asset, uint256 amount) external onlyAuthorizedWriter whenNotPaused {
        if (user == address(0)) revert ZeroAddress();
        if (asset == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        Balance storage b = _balances[user][asset];
        b.available += amount;

        emit Credited(msg.sender, user, asset, amount, b.available);
    }

    /// @inheritdoc IBalanceLedger
    function debit(address user, address asset, uint256 amount) external onlyAuthorizedWriter whenNotPaused {
        if (user == address(0)) revert ZeroAddress();
        if (asset == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        Balance storage b = _balances[user][asset];
        if (b.available < amount) revert InsufficientBalance();
        unchecked {
            b.available -= amount;
        }

        emit Debited(msg.sender, user, asset, amount, b.available);
    }

    // ============ Collateral Flag Mutators ============

    /// @inheritdoc IBalanceLedger
    function markCollateral(address user, address asset) external onlyAuthorizedWriter whenNotPaused {
        _setCollateralFlag(user, asset, true);
    }

    /// @inheritdoc IBalanceLedger
    function unmarkCollateral(address user, address asset) external onlyAuthorizedWriter whenNotPaused {
        _setCollateralFlag(user, asset, false);
    }

    // ============ Internal ============

    /// @dev Single source of truth for collateral-flag mutations. Idempotent
    ///      on both sides: already-flagged `true` and already-unflagged `false`
    ///      calls are no-ops and emit nothing. A repeat `true` MUST NOT refresh
    ///      `_flaggedAt` — the 24-hour flag-lock in `CollateralManager` is
    ///      pinned to the first mark so repeated borrows that reuse the same
    ///      collateral never extend the lockup.
    function _setCollateralFlag(address user, address asset, bool used) internal {
        if (user == address(0)) revert ZeroAddress();
        if (asset == address(0)) revert ZeroAddress();

        if (used) {
            if (_usedAsCollateral[user][asset]) return;
            // SC-5: bound the per-user flagged-collateral set. The RiskModule's HF
            // gate prices every flagged asset (one oracle call each); an unbounded
            // set lets a user push their own withdraw/unflag past the block gas
            // limit. Re-flagging an already-flagged asset (early-returned above)
            // never counts against the cap.
            if (_flaggedAssets[user].length() >= MAX_FLAGGED_ASSETS) revert TooManyFlaggedAssets();
            _usedAsCollateral[user][asset] = true;
            _flaggedAssets[user].add(asset);
            uint64 ts = uint64(block.timestamp);
            _flaggedAt[user][asset] = ts;
            emit CollateralFlagSet(msg.sender, user, asset, true, ts);
        } else {
            if (!_usedAsCollateral[user][asset]) return;
            _usedAsCollateral[user][asset] = false;
            _flaggedAssets[user].remove(asset);
            delete _flaggedAt[user][asset];
            emit CollateralFlagSet(msg.sender, user, asset, false, 0);
        }
    }

    // ============ Writer Management ============

    /// @inheritdoc IBalanceLedger
    function proposeAuthorizedWriter(address writer) external onlyOwner {
        if (writer == address(0)) revert ZeroAddress();
        if (_authorizedWriters[writer]) revert WriterAlreadyAuthorized();
        if (_writerProposals[writer].proposedAt != 0) revert WriterAlreadyProposed();

        _writerProposals[writer] = WriterProposal({proposedAt: block.timestamp});

        emit WriterProposed(writer, block.timestamp);
    }

    /// @inheritdoc IBalanceLedger
    function executeAuthorizedWriter(address writer) external onlyOwner {
        WriterProposal memory proposal = _writerProposals[writer];
        if (proposal.proposedAt == 0) revert WriterNotProposed();
        if (block.timestamp < proposal.proposedAt + WRITER_TIMELOCK) {
            revert WriterTimelockNotElapsed();
        }

        delete _writerProposals[writer];
        _authorizedWriters[writer] = true;

        emit WriterAdded(writer);
    }

    /// @inheritdoc IBalanceLedger
    function cancelWriterProposal(address writer) external onlyOwner {
        if (_writerProposals[writer].proposedAt == 0) revert WriterNotProposed();

        delete _writerProposals[writer];

        emit WriterProposalCancelled(writer);
    }

    /// @inheritdoc IBalanceLedger
    function forceAddWriter(address writer) external onlyOwner {
        if (!_forceWriterRegistrationEnabled) revert ForceRegistrationDisabled();
        if (writer == address(0)) revert ZeroAddress();
        if (_authorizedWriters[writer]) revert WriterAlreadyAuthorized();

        // Drop any pending proposal for this writer to keep state consistent.
        if (_writerProposals[writer].proposedAt != 0) {
            delete _writerProposals[writer];
        }

        _authorizedWriters[writer] = true;

        emit WriterAdded(writer);
    }

    /// @inheritdoc IBalanceLedger
    function removeAuthorizedWriter(address writer) external onlyOwner {
        if (!_authorizedWriters[writer]) revert WriterNotAuthorized();

        _authorizedWriters[writer] = false;

        emit WriterRemoved(writer);
    }

    // ============ Pause Control ============

    /// @inheritdoc IBalanceLedger
    function pause() external onlyPauser {
        _paused = true;
        emit Paused(msg.sender);
    }

    /// @inheritdoc IBalanceLedger
    function unpause() external onlyPauser {
        _paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Rotate the guardian (pauser) address. Owner-gated (the 24h timelock in prod).
    /// @param newPauser The new guardian address
    function setPauser(address newPauser) external onlyOwner {
        if (newPauser == address(0)) revert ZeroAddress();
        address oldPauser = _pauser;
        _pauser = newPauser;
        emit PauserUpdated(oldPauser, newPauser);
    }

    // ============ Views ============

    /// @inheritdoc IBalanceLedger
    function available(address user, address asset) external view returns (uint256) {
        return _balances[user][asset].available;
    }

    /// @inheritdoc IBalanceLedger
    function inOrders(address user, address asset) external view returns (uint256) {
        return _balances[user][asset].inOrders;
    }

    /// @inheritdoc IBalanceLedger
    function inYieldRouter(address user, address asset) external view returns (uint256) {
        return _balances[user][asset].inYieldRouter;
    }

    /// @inheritdoc IBalanceLedger
    function total(address user, address asset) external view returns (uint256) {
        Balance memory b = _balances[user][asset];
        return b.available + b.inOrders + b.inYieldRouter;
    }

    /// @inheritdoc IBalanceLedger
    function isAuthorizedWriter(address writer) external view returns (bool) {
        return _authorizedWriters[writer];
    }

    /// @inheritdoc IBalanceLedger
    function writerProposedAt(address writer) external view returns (uint256) {
        return _writerProposals[writer].proposedAt;
    }

    /// @inheritdoc IBalanceLedger
    function paused() external view returns (bool) {
        return _paused;
    }

    /// @notice The current guardian (pauser) address
    function pauser() external view returns (address) {
        return _pauser;
    }

    /// @inheritdoc IBalanceLedger
    function forceWriterRegistrationEnabled() external view returns (bool) {
        return _forceWriterRegistrationEnabled;
    }

    /// @inheritdoc IBalanceLedger
    function usedAsCollateral(address user, address asset) external view returns (bool) {
        return _usedAsCollateral[user][asset];
    }

    /// @inheritdoc IBalanceLedger
    function flaggedAssetsOf(address user) external view returns (address[] memory) {
        return _flaggedAssets[user].values();
    }

    /// @inheritdoc IBalanceLedger
    function flaggedAt(address user, address asset) external view returns (uint64) {
        return _flaggedAt[user][asset];
    }
}
