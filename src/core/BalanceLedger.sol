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

        _balances[user][asset].inYieldRouter = _balances[user][asset].inYieldRouter > amount
            ? _balances[user][asset].inYieldRouter - amount
            : 0;
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
    function deposit(address asset, uint256 amount) external whenNotPaused nonReentrant {
        if (amount == 0) revert ZeroAmount();

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        _balances[msg.sender][asset].available += amount;

        emit BalanceCredited(msg.sender, asset, amount);
    }

    /// @notice Withdraw tokens from the protocol — debits available balance and transfers ERC20
    /// @param asset The token to withdraw
    /// @param amount The amount to withdraw
    function withdraw(address asset, uint256 amount) external whenNotPaused nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (_balances[msg.sender][asset].available < amount) revert InsufficientAvailable();

        _balances[msg.sender][asset].available -= amount;
        IERC20(asset).safeTransfer(msg.sender, amount);

        emit BalanceDebited(msg.sender, asset, amount);
    }

    /// @notice Update cached USD value for a collateral position (called by CollateralRegistry)
    /// @param user The user address
    /// @param asset The collateral asset
    /// @param newUsdValue The new USD value
    function updateCollateralUsdValue(
        address user,
        address asset,
        uint256 newUsdValue
    ) external onlyAuthorized {
        for (uint256 i = 0; i < _collateral[user].length; i++) {
            if (_collateral[user][i].asset == asset) {
                _collateral[user][i].usdValueCached = newUsdValue;
                return;
            }
        }
    }

    // ============ Administrative Functions ============

    /// @notice Set authorized writer status (Security Invariant #9)
    /// @param writer The contract address
    /// @param authorized Whether to authorize
    function setAuthorizedWriter(address writer, bool authorized) external onlyOwner {
        if (writer == address(0)) revert ZeroAddress();
        _authorizedWriters[writer] = authorized;
        emit AuthorizedWriterUpdated(writer, authorized);
    }

    /// @notice Set the risk module address
    function setRiskModule(address riskModule_) external onlyOwner {
        _riskModule = riskModule_;
    }

    /// @notice Set the asset behavior registry address
    function setAssetBehaviorRegistry(address registry_) external onlyOwner {
        _assetBehaviorRegistry = registry_;
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
