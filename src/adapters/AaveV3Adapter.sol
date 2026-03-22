// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IYieldAdapter} from "../interfaces/IYieldAdapter.sol";

/// @title AaveV3Adapter
/// @notice IYieldAdapter wrapping Aave V3 supply/withdraw
/// @dev SECURITY: nonReentrant on all functions. Internal balance tracking (not balanceOf)
///      to prevent donation/inflation attacks.
contract AaveV3Adapter is IYieldAdapter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Aave V3 Pool address
    address public immutable POOL;

    /// @notice Internal balance tracking (adapter -> asset -> shares)
    /// @dev NOT using balanceOf to prevent donation attacks
    mapping(address => uint256) internal _totalDeployed;
    mapping(address => uint256) internal _totalShares;

    /// @notice Authorized caller (YieldRouter only)
    address public immutable YIELD_ROUTER;

    modifier onlyRouter() {
        require(msg.sender == YIELD_ROUTER, "AaveV3Adapter: only router");
        _;
    }

    constructor(address pool_, address yieldRouter_) {
        POOL = pool_;
        YIELD_ROUTER = yieldRouter_;
    }

    /// @inheritdoc IYieldAdapter
    function deploy(address asset, uint256 amount) external override onlyRouter nonReentrant returns (uint256 shares) {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(asset).forceApprove(POOL, amount);

        // Call Aave supply
        (bool success,) = POOL.call(
            abi.encodeWithSignature("supply(address,uint256,address,uint16)", asset, amount, address(this), 0)
        );
        require(success, "AaveV3Adapter: supply failed");

        // Internal accounting: 1:1 shares for simplicity
        shares = _totalShares[asset] == 0 ? amount : (amount * _totalShares[asset]) / _totalDeployed[asset];
        _totalDeployed[asset] += amount;
        _totalShares[asset] += shares;
    }

    /// @inheritdoc IYieldAdapter
    function recall(address asset, uint256 shares) external override onlyRouter nonReentrant returns (uint256 amount) {
        require(_totalShares[asset] >= shares, "AaveV3Adapter: insufficient shares");

        amount = (shares * _totalDeployed[asset]) / _totalShares[asset];
        _totalShares[asset] -= shares;
        _totalDeployed[asset] -= amount;

        // Call Aave withdraw
        (bool success, bytes memory data) = POOL.call(
            abi.encodeWithSignature("withdraw(address,uint256,address)", asset, amount, msg.sender)
        );
        require(success, "AaveV3Adapter: withdraw failed");
    }

    /// @inheritdoc IYieldAdapter
    function getDeployedValue(address asset, uint256 shares) external view override returns (uint256) {
        if (_totalShares[asset] == 0) return 0;
        return (shares * _totalDeployed[asset]) / _totalShares[asset];
    }

    /// @inheritdoc IYieldAdapter
    function getAPY(address asset) external view override returns (uint256) {
        return 500; // Mock: 5% APY
    }

    /// @inheritdoc IYieldAdapter
    function isAvailable(address) external pure override returns (bool) {
        return true;
    }

    /// @inheritdoc IYieldAdapter
    function canRecall(address asset, uint256 shares) external view override returns (bool) {
        return _totalShares[asset] >= shares;
    }
}
