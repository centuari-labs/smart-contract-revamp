// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "../utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IYieldAdapter} from "../interfaces/IYieldAdapter.sol";
import {YieldRouterStorage} from "./YieldRouterStorage.sol";

/// @title YieldRouter
/// @notice Thin token-movement proxy for idle yield deployment.
/// @dev All complex logic (deployment decisions, per-user yield, rebalancing, allocation)
///      is handled OFF-CHAIN by the Centuari engine. This contract only moves tokens
///      between BalanceLedger and yield adapters (Aave, Compound, Morpho).
///
///      On-chain verifiability: adapter.getDeployedValue() reads actual Aave/Compound
///      balance. CentuariEndpoint enforces totalYieldCredited <= actualYieldEarned.
///      Merkle roots committed per sweep for per-user transparency.
///
///      Security: deployToProtocol/recallFromProtocol are onlyAuthorized (engine/endpoint).
///      pauseAdapter is onlyMultisig (emergency). registerAdapter uses 48h timelock.
contract YieldRouter is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    YieldRouterStorage
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

    // ============ Errors ============

    error ZeroAddress();
    error ZeroAmount();
    error Unauthorized();
    error AdapterPausedError(address adapter);
    error AdapterNotRegistered(address adapter);

    // ============ Events ============

    event Deployed(address indexed asset, address indexed adapter, uint256 amount);
    event Recalled(address indexed asset, address indexed adapter, uint256 requested, uint256 returned);
    event AdapterPaused(address indexed adapter, uint256 expiresAt);
    event EmergencyRecalled(address indexed asset, address indexed adapter, uint256 amount);

    // ============ Modifiers ============

    modifier onlyMultisig() {
        if (msg.sender != _multisig) revert Unauthorized();
        _;
    }

    modifier onlyAuthorized() {
        if (!_authorizedCallers[msg.sender]) revert Unauthorized();
        _;
    }

    // ============ Core: Token Movement ============

    /// @notice Deploy tokens from BalanceLedger to a yield adapter.
    /// @dev Called by engine via settlement batch. Transfers tokens from BalanceLedger
    ///      to this contract, then to the adapter (Aave/Compound/Morpho).
    /// @param asset The token to deploy (e.g., USDC)
    /// @param amount Amount to deploy in token units
    /// @param adapter The yield adapter contract
    function deployToProtocol(
        address asset,
        uint256 amount,
        address adapter
    ) external onlyAuthorized nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (isAdapterPaused(adapter)) revert AdapterPausedError(adapter);
        if (!_isRegisteredAdapter[adapter]) revert AdapterNotRegistered(adapter);

        // Transfer from BalanceLedger to this contract
        IERC20(asset).safeTransferFrom(_balanceLedger, address(this), amount);

        // Deploy to adapter
        IERC20(asset).forceApprove(adapter, amount);
        IYieldAdapter(adapter).deploy(asset, amount);

        // Update protocol-level tracking
        _totalDeployed[asset] += amount;
        _adapterDeployed[adapter][asset] += amount;

        emit Deployed(asset, adapter, amount);
    }

    /// @notice Recall tokens from a yield adapter back to BalanceLedger.
    /// @dev Called by engine via settlement batch (before matches that need recalled capital).
    ///      Adapter withdraws from Aave/Compound/Morpho and sends tokens to BalanceLedger.
    /// @param asset The token to recall
    /// @param amount Amount to recall in token units
    /// @param adapter The yield adapter contract
    /// @return recalled Actual amount returned (may include yield)
    function recallFromProtocol(
        address asset,
        uint256 amount,
        address adapter
    ) external onlyAuthorized nonReentrant returns (uint256 recalled) {
        if (amount == 0) revert ZeroAmount();

        // Recall from adapter — may return more than requested (yield)
        recalled = IYieldAdapter(adapter).recall(asset, amount);

        // Send tokens to BalanceLedger
        IERC20(asset).safeTransfer(_balanceLedger, recalled);

        // Update tracking — clamp to prevent underflow if recalled > deployed
        uint256 adapterAmount = _adapterDeployed[adapter][asset];
        uint256 totalAmount = _totalDeployed[asset];
        _adapterDeployed[adapter][asset] = amount > adapterAmount ? 0 : adapterAmount - amount;
        _totalDeployed[asset] = amount > totalAmount ? 0 : totalAmount - amount;

        emit Recalled(asset, adapter, amount, recalled);
    }

    /// @notice Emergency recall ALL capital from a specific adapter. Multisig only, no timelock.
    /// @dev Conservative action — gets capital out of a potentially compromised adapter.
    ///      Used when: adapter exploit detected, protocol pause, engine offline.
    /// @param asset The token to recall
    /// @param adapter The adapter to recall from
    function emergencyRecall(
        address asset,
        address adapter
    ) external onlyMultisig nonReentrant {
        uint256 deployed = _adapterDeployed[adapter][asset];
        if (deployed == 0) return;

        uint256 recalled = IYieldAdapter(adapter).recall(asset, deployed);
        IERC20(asset).safeTransfer(_balanceLedger, recalled);

        _adapterDeployed[adapter][asset] = 0;
        _totalDeployed[asset] = _totalDeployed[asset] > deployed
            ? _totalDeployed[asset] - deployed
            : 0;

        emit EmergencyRecalled(asset, adapter, recalled);
    }

    // ============ View: On-Chain Verifiability ============

    /// @notice Get actual deployed value for an asset in an adapter (reads from adapter).
    /// @dev Used for yield verification: actualYield = getAdapterValue() - totalDeployed
    function getAdapterValue(address asset, address adapter) external view returns (uint256) {
        return IYieldAdapter(adapter).getDeployedValue(asset, 0);
    }

    /// @notice Get total deployed amount for an asset across all adapters
    function getTotalDeployed(address asset) external view returns (uint256) {
        return _totalDeployed[asset];
    }

    /// @notice Get deployed amount for a specific adapter and asset
    function getAdapterDeployed(address adapter, address asset) external view returns (uint256) {
        return _adapterDeployed[adapter][asset];
    }

    // ============ Adapter Management ============

    /// @notice Pause an adapter — stops new deployments, allows recalls. Multisig only.
    /// @dev 72h auto-expiry. No timelock (conservative action — reduces exposure).
    function pauseAdapter(address adapter) external onlyMultisig {
        _adapterPauseExpiry[adapter] = block.timestamp + ADAPTER_PAUSE_DURATION;
        emit AdapterPaused(adapter, _adapterPauseExpiry[adapter]);
    }

    /// @notice Check if an adapter is currently paused
    function isAdapterPaused(address adapter) public view returns (bool) {
        return block.timestamp < _adapterPauseExpiry[adapter];
    }

    // ============ Administrative (48h Timelock) ============

    function proposeAdapter(address adapter) external onlyOwner {
        require(adapter != address(0), "YieldRouter: zero address");
        _pendingAdapter = adapter;
        _pendingAdapterTimelockEnd = block.timestamp + ADMIN_TIMELOCK;
    }

    function applyAdapter() external onlyOwner {
        require(_pendingAdapter != address(0), "YieldRouter: no pending adapter");
        require(block.timestamp >= _pendingAdapterTimelockEnd, "YieldRouter: timelock active");
        _registeredAdapters.push(_pendingAdapter);
        _isRegisteredAdapter[_pendingAdapter] = true;
        delete _pendingAdapter;
        delete _pendingAdapterTimelockEnd;
    }

    function cancelAdapterProposal() external onlyOwner {
        delete _pendingAdapter;
        delete _pendingAdapterTimelockEnd;
    }

    function removeAdapter(address adapter) external onlyOwner {
        require(_adapterDeployed[adapter][address(0)] == 0, "YieldRouter: adapter has deployed capital");
        _isRegisteredAdapter[adapter] = false;
        // Remove from array (swap-and-pop)
        for (uint256 i = 0; i < _registeredAdapters.length; i++) {
            if (_registeredAdapters[i] == adapter) {
                _registeredAdapters[i] = _registeredAdapters[_registeredAdapters.length - 1];
                _registeredAdapters.pop();
                break;
            }
        }
    }

    function proposeAuthorizedCallerChange(address caller, bool authorized) external onlyOwner {
        if (caller == address(0)) revert ZeroAddress();
        _pendingAdminAddress[bytes32(uint256(uint160(caller)))] = caller;
        _pendingAdminBool[caller] = authorized;
        _pendingAdminTimelockEnd[bytes32(uint256(uint160(caller)))] = block.timestamp + ADMIN_TIMELOCK;
    }

    function applyAuthorizedCallerChange(address caller) external onlyOwner {
        bytes32 key = bytes32(uint256(uint160(caller)));
        require(_pendingAdminAddress[key] != address(0), "YieldRouter: no pending change");
        require(block.timestamp >= _pendingAdminTimelockEnd[key], "YieldRouter: timelock active");
        _authorizedCallers[caller] = _pendingAdminBool[caller];
        delete _pendingAdminAddress[key];
        delete _pendingAdminTimelockEnd[key];
        delete _pendingAdminBool[caller];
    }

    function cancelAuthorizedCallerChange(address caller) external onlyOwner {
        bytes32 key = bytes32(uint256(uint160(caller)));
        delete _pendingAdminAddress[key];
        delete _pendingAdminTimelockEnd[key];
        delete _pendingAdminBool[caller];
    }

    function proposeMultisig(address multisig_) external onlyOwner {
        if (multisig_ == address(0)) revert ZeroAddress();
        bytes32 key = keccak256("multisig");
        _pendingAdminAddress[key] = multisig_;
        _pendingAdminTimelockEnd[key] = block.timestamp + ADMIN_TIMELOCK;
    }

    function applyMultisig() external onlyOwner {
        bytes32 key = keccak256("multisig");
        require(_pendingAdminAddress[key] != address(0), "YieldRouter: no pending multisig");
        require(block.timestamp >= _pendingAdminTimelockEnd[key], "YieldRouter: timelock active");
        _multisig = _pendingAdminAddress[key];
        delete _pendingAdminAddress[key];
        delete _pendingAdminTimelockEnd[key];
    }

    function cancelMultisigProposal() external onlyOwner {
        bytes32 key = keccak256("multisig");
        delete _pendingAdminAddress[key];
        delete _pendingAdminTimelockEnd[key];
    }
}
