// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "../utils/ReentrancyGuardUpgradeable.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBalanceLedger} from "../interfaces/IBalanceLedger.sol";
import {IRiskModule} from "../interfaces/IRiskModule.sol";
import {IAssetBehaviorRegistry} from "../interfaces/IAssetBehaviorRegistry.sol";
import {BalanceLedgerStorage} from "./BalanceLedgerStorage.sol";

/// @title BalanceLedger
/// @notice Single source of truth for all user balances in the Centuari protocol
/// @dev Tracks stablecoin balances (available/locked/inYieldRouter/yieldRouterShares)
///      and collateral positions. Write access restricted to authorized contracts only.
///      Security Invariant #9: writes restricted to CentuariEndpoint, WithdrawalRegistry,
///      YieldRouter, and LiquidationEngine.
contract BalanceLedger is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    BalanceLedgerStorage,
    IBalanceLedger
{
    using SafeERC20 for IERC20;

    // ============ Constructor ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initializer ============

    /// @param owner_ The owner address
    function initialize(address owner_) external initializer {
        if (owner_ == address(0)) revert ZeroAddress();
        __Ownable_init(owner_);
        __ReentrancyGuard_init();
    }

    // ============ Modifiers ============

    /// @notice Restricts write access to authorized contracts (Security Invariant #9)
    modifier onlyAuthorized() {
        if (!_authorizedWriters[msg.sender]) revert Unauthorized();
        _;
    }

    modifier whenNotPaused() {
        require(!_paused, "BalanceLedger: paused");
        _;
    }

    // ============ Balance Operations ============

    /// @inheritdoc IBalanceLedger
    function credit(
        address user,
        address asset,
        uint256 amount
    ) external override onlyAuthorized whenNotPaused nonReentrant {
        if (user == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        _balances[user][asset].available += amount;
        emit BalanceCredited(user, asset, amount);
    }

    /// @inheritdoc IBalanceLedger
    function debit(
        address user,
        address asset,
        uint256 amount
    ) external override onlyAuthorized whenNotPaused nonReentrant {
        if (user == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (_balances[user][asset].available < amount) revert InsufficientAvailable();

        _balances[user][asset].available -= amount;
        emit BalanceDebited(user, asset, amount);
    }

    /// @inheritdoc IBalanceLedger
    function lockForOrder(
        address user,
        address asset,
        uint256 amount
    ) external override onlyAuthorized whenNotPaused nonReentrant {
        if (user == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (_balances[user][asset].available < amount) revert InsufficientAvailable();

        _balances[user][asset].available -= amount;
        _balances[user][asset].locked += amount;
        emit OrderLocked(user, asset, amount);
    }

    /// @inheritdoc IBalanceLedger
    function unlockFromOrder(
        address user,
        address asset,
        uint256 amount
    ) external override onlyAuthorized whenNotPaused nonReentrant {
        if (user == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (_balances[user][asset].locked < amount) revert InsufficientLocked();

        _balances[user][asset].locked -= amount;
        _balances[user][asset].available += amount;
        emit OrderUnlocked(user, asset, amount);
    }

    /// @inheritdoc IBalanceLedger
    function moveToYieldRouter(
        address user,
        address asset,
        uint256 amount,
        uint256 shares
    ) external override onlyAuthorized whenNotPaused nonReentrant {
        if (user == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (_balances[user][asset].available < amount) revert InsufficientAvailable();

        _balances[user][asset].available -= amount;
        _balances[user][asset].inYieldRouter += amount;
        _balances[user][asset].yieldRouterShares += shares;
        emit YieldRouterDeposited(user, asset, amount, shares);
    }

    /// @inheritdoc IBalanceLedger
    function moveFromYieldRouter(
        address user,
        address asset,
        uint256 amount,
        uint256 shares
    ) external override onlyAuthorized whenNotPaused nonReentrant {
        if (user == address(0)) revert ZeroAddress();
        if (_balances[user][asset].yieldRouterShares < shares) revert InsufficientYieldRouter();

        // M-05 FIX: Revert instead of silently clamping to 0. Clamping masks accounting bugs.
        if (_balances[user][asset].inYieldRouter < amount) revert InsufficientYieldRouter();
        _balances[user][asset].inYieldRouter -= amount;
        _balances[user][asset].yieldRouterShares -= shares;
        _balances[user][asset].available += amount;
        emit YieldRouterWithdrawn(user, asset, amount, shares);
    }

    // ============ Collateral Operations ============

    /// @inheritdoc IBalanceLedger
    function addCollateral(
        address user,
        address asset,
        uint256 amount,
        uint256 sourceChainId
    ) external override onlyAuthorized whenNotPaused nonReentrant {
        if (user == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        // Check if user already has a position for this asset
        bool found = false;
        for (uint256 i = 0; i < _collateral[user].length; i++) {
            if (_collateral[user][i].asset == asset && _collateral[user][i].sourceChainId == sourceChainId) {
                _collateral[user][i].amount += amount;
                found = true;
                break;
            }
        }

        if (!found) {
            _collateral[user].push(CollateralPosition({
                asset: asset,
                amount: amount,
                lockedShares: 0,
                lastAttestationTs: block.timestamp,
                usdValueCached: 0,
                sourceChainId: sourceChainId,
                spokeVaultId: bytes32(0),
                state: CollateralState.ACTIVE
            }));
        }

        // Default: enable as collateral
        _isUsedAsCollateral[user][asset] = true;

        emit CollateralAdded(user, asset, amount, sourceChainId);
    }

    /// @inheritdoc IBalanceLedger
    function setAsCollateral(
        address asset,
        bool useAsCollateral
    ) external override whenNotPaused nonReentrant {
        if (!useAsCollateral && _riskModule != address(0)) {
            // Safety check: cannot disable if it would put HF below 1.0
            uint256 newWeightedColl = IRiskModule(_riskModule).getWeightedCollateralExcluding(
                msg.sender, asset
            );
            uint256 totalDebt = IRiskModule(_riskModule).getTotalDebtUSD(msg.sender);
            if (totalDebt > 0 && newWeightedColl < totalDebt) {
                revert WouldCauseUndercollateralization();
            }
        }

        _isUsedAsCollateral[msg.sender][asset] = useAsCollateral;
        emit CollateralToggled(msg.sender, asset, useAsCollateral);
    }

    /// @inheritdoc IBalanceLedger
    function freezeCollateral(
        address user,
        uint256 collateralIndex
    ) external override onlyAuthorized whenNotPaused nonReentrant {
        if (collateralIndex >= _collateral[user].length) revert CollateralNotFound();
        CollateralPosition storage pos = _collateral[user][collateralIndex];
        if (pos.state != CollateralState.ACTIVE) revert CollateralNotActive();

        pos.state = CollateralState.FROZEN;
        emit CollateralFrozen(user, pos.asset, pos.amount);
    }

    /// @inheritdoc IBalanceLedger
    function reduceCollateral(
        address user,
        address asset,
        uint256 amount
    ) external override onlyAuthorized whenNotPaused nonReentrant {
        if (user == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        bool found = false;
        for (uint256 i = 0; i < _collateral[user].length; i++) {
            if (_collateral[user][i].asset == asset && _collateral[user][i].state == CollateralState.ACTIVE) {
                if (_collateral[user][i].amount < amount) revert InsufficientCollateral();
                _collateral[user][i].amount -= amount;
                found = true;
                break;
            }
        }

        if (!found) revert CollateralNotFound();
        emit CollateralReduced(user, asset, amount);
    }

    // ============ User-Facing Deposit / Withdraw ============

    /// @notice Deposit tokens into the protocol — transfers ERC20 and credits available balance
    /// @param asset The token to deposit
    /// @param amount The amount to deposit
    /// @dev 2I FIX: Uses before/after balanceOf to handle fee-on-transfer tokens.
    ///      Credits actual received amount, not requested amount.
    function deposit(address asset, uint256 amount) external whenNotPaused nonReentrant {
        if (amount == 0) revert ZeroAmount();

        uint256 balBefore = IERC20(asset).balanceOf(address(this));
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(asset).balanceOf(address(this)) - balBefore;

        _balances[msg.sender][asset].available += received;

        emit BalanceCredited(msg.sender, asset, received);
    }

    /// @notice Withdraw tokens from the protocol — debits available balance and transfers ERC20
    /// @dev H-01 FIX: Check health factor after debiting. Without this, a borrower could
    ///      withdraw all available balance and drop their HF below 1.0 without liquidation.
    /// @dev P1-b FIX: No whenNotPaused — users MUST always be able to withdraw (Invariant #21)
    /// @param asset The token to withdraw
    /// @param amount The amount to withdraw
    function withdraw(address asset, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (_balances[msg.sender][asset].available < amount) revert InsufficientAvailable();

        _balances[msg.sender][asset].available -= amount;

        // H-01 FIX: Verify withdrawal doesn't put user below liquidation threshold
        if (_riskModule != address(0)) {
            uint256 hf = IRiskModule(_riskModule).getHealthFactor(msg.sender);
            // type(uint256).max means no debt — always safe
            if (hf != type(uint256).max && hf < 1e18) {
                revert WouldCauseUndercollateralization();
            }
        }

        IERC20(asset).safeTransfer(msg.sender, amount);
        emit BalanceDebited(msg.sender, asset, amount);
    }

    /// @notice Transfer ERC20 tokens out of the ledger (for CBT redemption)
    /// @dev C-05 FIX: CentuariEndpoint calls this during redeemCBT() to release underlying.
    ///      Does NOT modify user balances — only moves ERC20 tokens the ledger contract holds.
    /// @param asset The token to transfer
    /// @param to The recipient address
    /// @param amount The amount to transfer
    function transferOut(
        address asset,
        address to,
        uint256 amount
    ) external onlyAuthorized whenNotPaused nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        IERC20(asset).safeTransfer(to, amount);
    }

    /// @notice Update cached USD value for a collateral position (called by CollateralRegistry)
    /// @param user The user address
    /// @param asset The collateral asset
    /// @param newUsdValue The new USD value
    function updateCollateralUsdValue(
        address user,
        address asset,
        uint256 newUsdValue
    ) external onlyAuthorized nonReentrant {
        for (uint256 i = 0; i < _collateral[user].length; i++) {
            if (_collateral[user][i].asset == asset) {
                _collateral[user][i].usdValueCached = newUsdValue;
                return;
            }
        }
    }

    // ============ Administrative Functions ============

    /// @notice P1-e FIX: Propose authorized writer change (48h timelock)
    /// @dev Most critical admin setter — controls who can modify all user balances.
    /// @param writer The contract address to authorize or deauthorize
    /// @param authorized Whether to grant or revoke write access
    function proposeAuthorizedWriter(address writer, bool authorized) external onlyOwner {
        if (writer == address(0)) revert ZeroAddress();
        _pendingWriterAddress = writer;
        _pendingWriterAuthorized = authorized;
        _pendingWriterTimelockEnd = block.timestamp + 48 hours;
        emit AuthorizedWriterProposed(writer, authorized, block.timestamp + 48 hours);
    }

    /// @notice Apply pending authorized writer change after timelock
    function applyAuthorizedWriter() external onlyOwner {
        require(_pendingWriterAddress != address(0), "BalanceLedger: no pending writer");
        require(block.timestamp >= _pendingWriterTimelockEnd, "BalanceLedger: timelock active");
        _authorizedWriters[_pendingWriterAddress] = _pendingWriterAuthorized;
        emit AuthorizedWriterUpdated(_pendingWriterAddress, _pendingWriterAuthorized);
        delete _pendingWriterAddress;
        delete _pendingWriterAuthorized;
        delete _pendingWriterTimelockEnd;
    }

    /// @notice Cancel pending writer proposal
    function cancelWriterProposal() external onlyOwner {
        delete _pendingWriterAddress;
        delete _pendingWriterAuthorized;
        delete _pendingWriterTimelockEnd;
    }

    /// @notice Propose an admin address change with 48h timelock
    /// @dev Used for setRiskModule and setAssetBehaviorRegistry.
    ///      Keys: keccak256("riskModule") and keccak256("assetBehaviorRegistry")
    /// @param key  A bytes32 identifier for the parameter being changed
    /// @param newAddr The new address to set after the timelock
    function proposeAdminChange(bytes32 key, address newAddr) external onlyOwner {
        if (newAddr == address(0)) revert ZeroAddress();
        _pendingAdminAddress[key] = newAddr;
        _pendingAdminTimelockEnd[key] = block.timestamp + 48 hours;
        emit AdminChangeProposed(key, newAddr, block.timestamp + 48 hours);
    }

    /// @notice Apply a pending admin address change after the 48h timelock has elapsed
    /// @param key The bytes32 identifier used in proposeAdminChange
    function applyAdminChange(bytes32 key) external onlyOwner {
        address newAddr = _pendingAdminAddress[key];
        require(newAddr != address(0), "BalanceLedger: no pending change");
        require(block.timestamp >= _pendingAdminTimelockEnd[key], "BalanceLedger: timelock active");

        if (key == "riskModule") {
            _riskModule = newAddr;
        } else if (key == "registry") {
            _assetBehaviorRegistry = newAddr;
        } else {
            revert("BalanceLedger: unknown key");
        }

        emit AdminChangeApplied(key, newAddr);
        delete _pendingAdminAddress[key];
        delete _pendingAdminTimelockEnd[key];
    }

    /// @notice Cancel a pending admin address change
    /// @param key The bytes32 identifier used in proposeAdminChange
    function cancelAdminChange(bytes32 key) external onlyOwner {
        delete _pendingAdminAddress[key];
        delete _pendingAdminTimelockEnd[key];
        emit AdminChangeCancelled(key);
    }

    /// @notice Pause the contract
    function pause() external onlyOwner {
        _paused = true;
    }

    /// @notice Unpause the contract
    function unpause() external onlyOwner {
        _paused = false;
    }

    // ============ View Functions ============

    /// @inheritdoc IBalanceLedger
    function getBalance(address user, address asset) external view override returns (UserBalance memory) {
        return _balances[user][asset];
    }

    /// @inheritdoc IBalanceLedger
    function getAvailable(address user, address asset) external view override returns (uint256) {
        return _balances[user][asset].available;
    }

    /// @inheritdoc IBalanceLedger
    function getLocked(address user, address asset) external view override returns (uint256) {
        return _balances[user][asset].locked;
    }

    /// @inheritdoc IBalanceLedger
    function getCollateral(address user) external view override returns (CollateralPosition[] memory) {
        return _collateral[user];
    }

    /// @inheritdoc IBalanceLedger
    function getCollateralByAsset(
        address user,
        address asset
    ) external view override returns (CollateralPosition memory) {
        for (uint256 i = 0; i < _collateral[user].length; i++) {
            if (_collateral[user][i].asset == asset) {
                return _collateral[user][i];
            }
        }
        revert CollateralNotFound();
    }

    /// @inheritdoc IBalanceLedger
    function getIsUsedAsCollateral(address user, address asset) external view override returns (bool) {
        return _isUsedAsCollateral[user][asset];
    }

    /// @inheritdoc IBalanceLedger
    function isAuthorizedWriter(address writer) external view override returns (bool) {
        return _authorizedWriters[writer];
    }
}
