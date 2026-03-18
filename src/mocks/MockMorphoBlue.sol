// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MockMorphoBlue
/// @notice Simplified Morpho Blue mock for YieldRouter adapter testing
/// @dev Uses share-based accounting similar to ERC-4626 vaults.
contract MockMorphoBlue {
    using SafeERC20 for IERC20;

    mapping(address => uint256) public userShares;
    uint256 public totalShares;
    uint256 public totalAssets;
    address public asset;
    bool public available = true;

    constructor(address asset_) {
        asset = asset_;
    }

    function setAvailable(bool available_) external {
        available = available_;
    }

    /// @notice Inject yield to simulate interest accrual
    function injectYield(uint256 amount) external {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        totalAssets += amount;
    }

    function supply(uint256 amount) external returns (uint256 shares) {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        shares = totalShares == 0 ? amount : (amount * totalShares) / totalAssets;
        userShares[msg.sender] += shares;
        totalShares += shares;
        totalAssets += amount;
    }

    function withdraw(uint256 shares) external returns (uint256 amount) {
        require(available, "MockMorpho: liquidity unavailable");
        require(userShares[msg.sender] >= shares, "MockMorpho: insufficient shares");

        amount = (shares * totalAssets) / totalShares;
        userShares[msg.sender] -= shares;
        totalShares -= shares;
        totalAssets -= amount;

        IERC20(asset).safeTransfer(msg.sender, amount);
    }

    function getShareValue(uint256 shares) external view returns (uint256) {
        if (totalShares == 0) return shares;
        return (shares * totalAssets) / totalShares;
    }
}
