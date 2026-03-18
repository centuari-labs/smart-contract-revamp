// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MockAaveV3Pool
/// @notice Simplified Aave V3 Pool mock for YieldRouter adapter testing
/// @dev Tracks deposits/withdrawals with configurable yield. Uses 1:1 share rate.
contract MockAaveV3Pool {
    using SafeERC20 for IERC20;

    /// @notice Per-user per-asset supply balance
    mapping(address => mapping(address => uint256)) public supplies;

    /// @notice Configurable APY per asset (in BPS, e.g., 500 = 5%)
    mapping(address => uint256) public apyBPS;

    /// @notice Track when supply was last updated for yield computation
    mapping(address => mapping(address => uint256)) public lastSupplyTime;

    /// @notice Total supplied per asset
    mapping(address => uint256) public totalSupplied;

    /// @notice Simulated availability (false = liquidity crunch, recall would fail)
    bool public available = true;

    function setAPY(address asset, uint256 bps) external {
        apyBPS[asset] = bps;
    }

    function setAvailable(bool available_) external {
        available = available_;
    }

    /// @notice Supply asset to the pool
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 /*referralCode*/) external {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        supplies[onBehalfOf][asset] += amount;
        lastSupplyTime[onBehalfOf][asset] = block.timestamp;
        totalSupplied[asset] += amount;
    }

    /// @notice Withdraw asset from the pool
    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        require(available, "MockAave: liquidity unavailable");
        uint256 userBal = supplies[msg.sender][asset];
        uint256 withdrawAmount = amount > userBal ? userBal : amount;

        supplies[msg.sender][asset] -= withdrawAmount;
        totalSupplied[asset] -= withdrawAmount;

        IERC20(asset).safeTransfer(to, withdrawAmount);
        return withdrawAmount;
    }

    /// @notice Get user supply balance (no yield accrual in mock — keep simple)
    function getSupply(address user, address asset) external view returns (uint256) {
        return supplies[user][asset];
    }
}
