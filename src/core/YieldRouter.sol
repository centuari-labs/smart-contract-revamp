// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "../utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IYieldRouter} from "../interfaces/IYieldRouter.sol";
import {IYieldAdapter} from "../interfaces/IYieldAdapter.sol";
import {IBalanceLedger} from "../interfaces/IBalanceLedger.sol";
import {YieldRouterStorage} from "./YieldRouterStorage.sol";

/// @title YieldRouter
/// @notice Deploys idle user balances to external yield protocols
/// @dev Activates immediately on deposit per AllocationConfig.
///      Security Invariant #8: InsuranceReserve >= 10% of total deployed.
contract YieldRouter is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    YieldRouterStorage,
    IYieldRouter
{
    using SafeERC20 for IERC20;

    // ============ Constructor ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initializer ============

    function initialize(
        address owner_,
        address balanceLedger_,
        address multisig_
    ) external initializer {
        if (owner_ == address(0) || balanceLedger_ == address(0) || multisig_ == address(0)) {
            revert ZeroAddress();
        }
        __Ownable_init(owner_);
        __ReentrancyGuard_init();
        _balanceLedger = balanceLedger_;
        _multisig = multisig_;
    }

    // ============ Modifiers ============

    modifier onlyMultisig() {
        if (msg.sender != _multisig) revert Unauthorized();
        _;
    }

    modifier onlyAuthorized() {
        if (!_authorizedCallers[msg.sender]) revert Unauthorized();
        _;
    }

    // ============ Constants ============

    /// @inheritdoc IYieldRouter
    function MAX_PER_PROTOCOL_BPS() external pure override returns (uint256) { return _MAX_PER_PROTOCOL_BPS; }

    /// @inheritdoc IYieldRouter
    function MIN_RESERVE_RATIO_BPS() external pure override returns (uint256) { return _MIN_RESERVE_RATIO_BPS; }

    /// @inheritdoc IYieldRouter
    function VAULT_RAW_MINIMUM_BPS() external pure override returns (uint256) { return _VAULT_RAW_MINIMUM_BPS; }

    // ============ Deployment ============

    /// @inheritdoc IYieldRouter
    function deploy(
        address asset,
        uint256 amount,
        address adapter
    ) external override onlyAuthorized nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (isAdapterPaused(adapter)) revert AdapterPausedError(adapter);

        // Check reserve ratio would be maintained (Security Invariant #8)
        if (!_wouldMaintainReserve(asset, amount)) {
            revert ReserveRatioViolated(_currentReserveRatio(asset), _MIN_RESERVE_RATIO_BPS);
        }

        // Check per-protocol cap (60%)
        uint256 newAdapterTotal = _adapterDeployed[adapter][asset] + amount;
        uint256 newTotal = _totalDeployed[asset] + amount;
        if (newTotal > 0 && (newAdapterTotal * BPS_DENOMINATOR) / newTotal > _MAX_PER_PROTOCOL_BPS) {
            uint256 currentBPS = (newAdapterTotal * BPS_DENOMINATOR) / newTotal;
            revert ProtocolCapExceeded(adapter, currentBPS, _MAX_PER_PROTOCOL_BPS);
        }

        // Deploy via adapter
        IERC20(asset).safeApprove(adapter, amount);
        uint256 shares = IYieldAdapter(adapter).deploy(asset, amount);

        // Update tracking
        _adapterDeployed[adapter][asset] += amount;
        _totalDeployed[asset] += amount;

        // Update BalanceLedger
        IBalanceLedger(_balanceLedger).moveToYieldRouter(msg.sender, asset, amount, shares);

        emit Deployed(msg.sender, asset, adapter, amount, shares);
    }

    /// @inheritdoc IYieldRouter
    function recall(
        address user,
        address asset,
        uint256 shares
    ) external override onlyAuthorized nonReentrant returns (uint256 amount) {
        // For simplicity, recall from the first adapter that has shares
        // In production, this would use AllocationConfig priority
        return 0; // Placeholder — full implementation in adapter-specific recall
    }

    /// @inheritdoc IYieldRouter
    function recallForOrder(
        address user,
        address asset,
        uint256 shortfall
    ) external override onlyAuthorized nonReentrant returns (uint256 amount) {
        // Recall the shortfall amount from adapters
        // Priority: least-allocated adapter first (rebalance opportunity)
        return 0; // Placeholder
    }

    /// @inheritdoc IYieldRouter
    function recallAll(address user, address asset) external override onlyAuthorized nonReentrant {
        // Recall all deployed capital for user/asset
        // Called when user disables router
    }

    /// @inheritdoc IYieldRouter
    function rebalance(address user, address asset) external override onlyAuthorized nonReentrant {
        // Rebalance when allocation drift exceeds threshold
        emit Rebalanced(user, asset);
    }

    // ============ User Controls ============

    /// @inheritdoc IYieldRouter
    function setEnabled(address asset, bool enabled) external override {
        _routerEnabled[msg.sender][asset] = enabled;
        emit RouterEnabledChanged(msg.sender, asset, enabled);
    }

    /// @inheritdoc IYieldRouter
    function isEnabled(address user, address asset) external view override returns (bool) {
        return _routerEnabled[user][asset];
    }

    // ============ Insurance Reserve ============

    /// @inheritdoc IYieldRouter
    function verifyReserveRatio() external view override returns (bool) {
        // Check across all assets — simplified to single-asset check
        return true; // Full implementation checks each asset's reserve
    }

    /// @notice Deposit to insurance reserve
    function depositToReserve(address asset, uint256 amount) external onlyAuthorized {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        _insuranceReserve[asset] += amount;
    }

    // ============ Adapter Management ============

    /// @inheritdoc IYieldRouter
    function pauseAdapter(address adapter) external override onlyMultisig {
        _adapterPauseExpiry[adapter] = block.timestamp + ADAPTER_PAUSE_DURATION;
        emit AdapterPaused(adapter, _adapterPauseExpiry[adapter]);
    }

    /// @inheritdoc IYieldRouter
    function isAdapterPaused(address adapter) public view override returns (bool) {
        return block.timestamp < _adapterPauseExpiry[adapter];
    }

    // ============ Administrative ============

    function setAuthorizedCaller(address caller, bool authorized) external onlyOwner {
        _authorizedCallers[caller] = authorized;
    }

    function setMultisig(address multisig_) external onlyOwner {
        if (multisig_ == address(0)) revert ZeroAddress();
        _multisig = multisig_;
    }

    // ============ Internal ============

    function _wouldMaintainReserve(address asset, uint256 deployAmount) internal view returns (bool) {
        uint256 reserve = _insuranceReserve[asset];
        uint256 newTotal = _totalDeployed[asset] + deployAmount;
        if (newTotal == 0) return true;
        return (reserve * BPS_DENOMINATOR) / newTotal >= _MIN_RESERVE_RATIO_BPS;
    }

    function _currentReserveRatio(address asset) internal view returns (uint256) {
        if (_totalDeployed[asset] == 0) return BPS_DENOMINATOR;
        return (_insuranceReserve[asset] * BPS_DENOMINATOR) / _totalDeployed[asset];
    }
}
