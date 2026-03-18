// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ISpokeVaultStable} from "../interfaces/ISpokeVaultStable.sol";

/// @title SpokeVaultStable
/// @notice Spoke chain vault for stablecoins (USDC, USDT, USDe)
/// @dev Locks deposits, maintains withdrawal buffer (HIGH/LOW WATER MARK).
contract SpokeVaultStable is ISpokeVaultStable, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    mapping(address => uint256) internal _balances;
    mapping(address => bool) internal _supportedAssets;
    address public sweeper;
    uint256 public highWaterMarkBPS = 300; // 3x rolling 24h avg
    uint256 public lowWaterMarkBPS = 100;  // 1x rolling 24h avg

    constructor(address owner_) Ownable(owner_) {}

    modifier onlySweeper() {
        require(msg.sender == sweeper || msg.sender == owner(), "SpokeVaultStable: unauthorized");
        _;
    }

    /// @inheritdoc ISpokeVaultStable
    function deposit(address asset, uint256 amount) external override nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (!_supportedAssets[asset]) revert UnsupportedAsset();
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        _balances[asset] += amount;
        emit Deposited(msg.sender, asset, amount);
    }

    /// @inheritdoc ISpokeVaultStable
    function withdraw(address asset, uint256 amount) external override nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (_balances[asset] < amount) revert InsufficientBuffer();
        _balances[asset] -= amount;
        IERC20(asset).safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, asset, amount);
    }

    /// @inheritdoc ISpokeVaultStable
    function sweepToHub(address asset, uint256 amount, bytes calldata) external override onlySweeper nonReentrant {
        if (_balances[asset] < amount) revert InsufficientBuffer();
        _balances[asset] -= amount;
        // In production: bridge via CCTP or LayerZero OFT
        // For mock: just reduce balance (Sweeper handles bridging)
        emit SweptToHub(asset, amount);
    }

    /// @inheritdoc ISpokeVaultStable
    function receiveFromHub(address asset, uint256 amount) external override onlySweeper {
        _balances[asset] += amount;
        emit ReceivedFromHub(asset, amount);
    }

    /// @inheritdoc ISpokeVaultStable
    function getBalance(address asset) external view override returns (uint256) { return _balances[asset]; }

    /// @inheritdoc ISpokeVaultStable
    function getBufferTarget(address asset) external view override returns (uint256) { return _balances[asset]; }

    function setSweeper(address s) external onlyOwner { sweeper = s; }
    function setSupportedAsset(address asset, bool supported) external onlyOwner { _supportedAssets[asset] = supported; }
}
