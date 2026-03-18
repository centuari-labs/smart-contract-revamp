// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IYieldAdapter} from "../interfaces/IYieldAdapter.sol";

/// @title MorphoAdapter
/// @notice IYieldAdapter wrapping Morpho Blue supply/withdraw
contract MorphoAdapter is IYieldAdapter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable MORPHO;
    address public immutable YIELD_ROUTER;

    mapping(address => uint256) internal _totalDeployed;
    mapping(address => uint256) internal _totalShares;

    modifier onlyRouter() {
        require(msg.sender == YIELD_ROUTER, "MorphoAdapter: only router");
        _;
    }

    constructor(address morpho_, address yieldRouter_) {
        MORPHO = morpho_;
        YIELD_ROUTER = yieldRouter_;
    }

    /// @inheritdoc IYieldAdapter
    function deploy(address asset, uint256 amount) external override onlyRouter nonReentrant returns (uint256 shares) {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(asset).safeApprove(MORPHO, amount);

        (bool success, bytes memory data) = MORPHO.call(abi.encodeWithSignature("supply(uint256)", amount));
        require(success, "MorphoAdapter: supply failed");

        shares = data.length > 0 ? abi.decode(data, (uint256)) : amount;
        _totalDeployed[asset] += amount;
        _totalShares[asset] += shares;
    }

    /// @inheritdoc IYieldAdapter
    function recall(address asset, uint256 shares) external override onlyRouter nonReentrant returns (uint256 amount) {
        require(_totalShares[asset] >= shares, "MorphoAdapter: insufficient");

        amount = (shares * _totalDeployed[asset]) / _totalShares[asset];
        _totalShares[asset] -= shares;
        _totalDeployed[asset] -= amount;

        (bool success,) = MORPHO.call(abi.encodeWithSignature("withdraw(uint256)", shares));
        require(success, "MorphoAdapter: withdraw failed");

        IERC20(asset).safeTransfer(msg.sender, amount);
    }

    /// @inheritdoc IYieldAdapter
    function getDeployedValue(address asset, uint256 shares) external view override returns (uint256) {
        if (_totalShares[asset] == 0) return 0;
        return (shares * _totalDeployed[asset]) / _totalShares[asset];
    }

    /// @inheritdoc IYieldAdapter
    function getAPY(address) external pure override returns (uint256) { return 350; } // 3.5%

    /// @inheritdoc IYieldAdapter
    function isAvailable(address) external pure override returns (bool) { return true; }

    /// @inheritdoc IYieldAdapter
    function canRecall(address asset, uint256 shares) external view override returns (bool) {
        return _totalShares[asset] >= shares;
    }
}
