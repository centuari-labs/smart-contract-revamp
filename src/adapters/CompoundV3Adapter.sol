// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IYieldAdapter} from "../interfaces/IYieldAdapter.sol";

/// @title CompoundV3Adapter
/// @notice IYieldAdapter wrapping Compound V3 (Comet) supply/withdraw
contract CompoundV3Adapter is IYieldAdapter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable COMET;
    address public immutable YIELD_ROUTER;

    mapping(address => uint256) internal _totalDeployed;
    mapping(address => uint256) internal _totalShares;

    modifier onlyRouter() {
        require(msg.sender == YIELD_ROUTER, "CompoundV3Adapter: only router");
        _;
    }

    constructor(address comet_, address yieldRouter_) {
        COMET = comet_;
        YIELD_ROUTER = yieldRouter_;
    }

    /// @inheritdoc IYieldAdapter
    function deploy(address asset, uint256 amount) external override onlyRouter nonReentrant returns (uint256 shares) {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(asset).safeApprove(COMET, amount);

        (bool success,) = COMET.call(abi.encodeWithSignature("supply(address,uint256)", asset, amount));
        require(success, "CompoundV3Adapter: supply failed");

        shares = _totalShares[asset] == 0 ? amount : (amount * _totalShares[asset]) / _totalDeployed[asset];
        _totalDeployed[asset] += amount;
        _totalShares[asset] += shares;
    }

    /// @inheritdoc IYieldAdapter
    function recall(address asset, uint256 shares) external override onlyRouter nonReentrant returns (uint256 amount) {
        require(_totalShares[asset] >= shares, "CompoundV3Adapter: insufficient");

        amount = (shares * _totalDeployed[asset]) / _totalShares[asset];
        _totalShares[asset] -= shares;
        _totalDeployed[asset] -= amount;

        (bool success,) = COMET.call(abi.encodeWithSignature("withdraw(address,uint256)", asset, amount));
        require(success, "CompoundV3Adapter: withdraw failed");

        IERC20(asset).safeTransfer(msg.sender, amount);
    }

    /// @inheritdoc IYieldAdapter
    function getDeployedValue(address asset, uint256 shares) external view override returns (uint256) {
        if (_totalShares[asset] == 0) return 0;
        return (shares * _totalDeployed[asset]) / _totalShares[asset];
    }

    /// @inheritdoc IYieldAdapter
    function getAPY(address) external pure override returns (uint256) { return 400; } // 4%

    /// @inheritdoc IYieldAdapter
    function isAvailable(address) external pure override returns (bool) { return true; }

    /// @inheritdoc IYieldAdapter
    function canRecall(address asset, uint256 shares) external view override returns (bool) {
        return _totalShares[asset] >= shares;
    }
}
