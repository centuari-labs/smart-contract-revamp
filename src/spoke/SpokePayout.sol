// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title SpokePayout
/// @notice Releases withdrawal funds to users on spoke chains
/// @dev Security Invariant #4: Cannot release without WithdrawalRegistry authorization.
contract SpokePayout is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice SpokeVaultStable to draw from
    address public spokeVault;

    /// @notice Hub WithdrawalRegistry address (source of authorization)
    address public withdrawalRegistry;

    /// @notice Authorized releases (requestId => authorized)
    mapping(bytes32 => bool) public authorizedReleases;

    /// @notice Queued withdrawals when buffer insufficient
    struct QueuedWithdrawal {
        address user;
        address asset;
        uint256 amount;
        bool released;
    }
    mapping(bytes32 => QueuedWithdrawal) public queue;

    event Released(bytes32 indexed requestId, address indexed user, address indexed asset, uint256 amount);
    event Queued(bytes32 indexed requestId, address indexed user, address indexed asset, uint256 amount);

    error Unauthorized();
    error NotAuthorized(bytes32 requestId);
    error AlreadyReleased(bytes32 requestId);
    error InsufficientBuffer();

    constructor(address owner_) Ownable(owner_) {}

    /// @notice Authorize a withdrawal release (called by hub via messaging)
    function authorize(bytes32 requestId) external {
        require(msg.sender == withdrawalRegistry || msg.sender == owner(), "SpokePayout: unauthorized");
        authorizedReleases[requestId] = true;
    }

    /// @notice Release funds to user (Security Invariant #4)
    function release(bytes32 requestId, address user, address asset, uint256 amount) external nonReentrant {
        if (!authorizedReleases[requestId]) revert NotAuthorized(requestId);

        QueuedWithdrawal storage q = queue[requestId];
        if (q.released) revert AlreadyReleased(requestId);

        uint256 balance = IERC20(asset).balanceOf(address(this));
        if (balance < amount) {
            // Queue for later when Sweeper replenishes
            queue[requestId] = QueuedWithdrawal({user: user, asset: asset, amount: amount, released: false});
            emit Queued(requestId, user, asset, amount);
            return;
        }

        queue[requestId] = QueuedWithdrawal({user: user, asset: asset, amount: amount, released: true});
        IERC20(asset).safeTransfer(user, amount);
        emit Released(requestId, user, asset, amount);
    }

    function setSpokeVault(address vault) external onlyOwner { spokeVault = vault; }
    function setWithdrawalRegistry(address wr) external onlyOwner { withdrawalRegistry = wr; }
}
