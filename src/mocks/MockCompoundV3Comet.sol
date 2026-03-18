// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MockCompoundV3Comet
/// @notice Simplified Compound V3 (Comet) mock for YieldRouter adapter testing
/// @dev Compound V3 tracks balances internally (no separate cToken).
contract MockCompoundV3Comet {
    using SafeERC20 for IERC20;

    mapping(address => uint256) public userSupply;
    mapping(address => uint256) public apyBPS;
    uint256 public totalSupply_;
    bool public available = true;

    address public baseToken;

    constructor(address baseToken_) {
        baseToken = baseToken_;
    }

    function setAPY(uint256 bps) external {
        apyBPS[baseToken] = bps;
    }

    function setAvailable(bool available_) external {
        available = available_;
    }

    function supply(address asset, uint256 amount) external {
        require(asset == baseToken, "MockComet: wrong asset");
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        userSupply[msg.sender] += amount;
        totalSupply_ += amount;
    }

    function withdraw(address asset, uint256 amount) external {
        require(asset == baseToken, "MockComet: wrong asset");
        require(available, "MockComet: liquidity unavailable");
        require(userSupply[msg.sender] >= amount, "MockComet: insufficient");

        userSupply[msg.sender] -= amount;
        totalSupply_ -= amount;
        IERC20(asset).safeTransfer(msg.sender, amount);
    }

    function balanceOf(address user) external view returns (uint256) {
        return userSupply[user];
    }
}
