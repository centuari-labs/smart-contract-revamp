// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title SpokePayout
/// @notice Releases withdrawal funds to users on spoke chains
/// @dev Security Invariant #4: Cannot release without WithdrawalRegistry authorization.
///      NC-03 FIX: Authorization details (user, asset, amount) are stored at authorize() time
///      and validated at release() time. Callers cannot substitute their own address.
contract SpokePayout is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice SpokeVaultStable to draw from
    address public spokeVault;

    /// @notice Hub WithdrawalRegistry address (source of authorization)
    address public withdrawalRegistry;

    /// @notice NC-03 FIX: Stores the FULL authorization details at authorize() time.
    ///         release() reads from this — no caller-supplied params for user/asset/amount.
    struct AuthorizedRelease {
        address user;
        address asset;
        uint256 amount;
        bool authorized;
        bool released;
    }
    mapping(bytes32 => AuthorizedRelease) public authorizations;

    /// @notice Queued withdrawal request IDs for processing after buffer replenishment
    bytes32[] public queuedRequestIds;

    event Released(bytes32 indexed requestId, address indexed user, address indexed asset, uint256 amount);
    event Queued(bytes32 indexed requestId, address indexed user, address indexed asset, uint256 amount);
    event QueuedReleaseProcessed(bytes32 indexed requestId, address indexed user, address indexed asset, uint256 amount);

    error NotAuthorized(bytes32 requestId);
    error AlreadyReleased(bytes32 requestId);

    constructor(address owner_) Ownable(owner_) {}

    /// @notice Authorize a withdrawal release with FULL details stored on-chain
    /// @dev NC-03 FIX: Stores user, asset, amount at authorization time.
    ///      release() reads these — caller cannot substitute different values.
    function authorize(
        bytes32 requestId,
        address user,
        address asset,
        uint256 amount
    ) external {
        require(msg.sender == withdrawalRegistry || msg.sender == owner(), "SpokePayout: unauthorized");
        require(user != address(0), "SpokePayout: zero user");
        require(amount > 0, "SpokePayout: zero amount");

        authorizations[requestId] = AuthorizedRelease({
            user: user,
            asset: asset,
            amount: amount,
            authorized: true,
            released: false
        });
    }

    /// @notice Release funds to user (Security Invariant #4)
    /// @dev NC-03 FIX: No caller-supplied user/asset/amount — reads from stored authorization.
    function release(bytes32 requestId) external nonReentrant {
        AuthorizedRelease storage auth = authorizations[requestId];
        if (!auth.authorized) revert NotAuthorized(requestId);
        if (auth.released) revert AlreadyReleased(requestId);

        uint256 balance = IERC20(auth.asset).balanceOf(address(this));
        if (balance < auth.amount) {
            queuedRequestIds.push(requestId);
            emit Queued(requestId, auth.user, auth.asset, auth.amount);
            return;
        }

        auth.released = true;
        IERC20(auth.asset).safeTransfer(auth.user, auth.amount);
        emit Released(requestId, auth.user, auth.asset, auth.amount);
    }

    /// @notice Process queued withdrawals after buffer replenishment
    /// @dev Called by Sweeper Bot or keeper after depositing funds into this contract.
    function processQueued() external nonReentrant {
        uint256 i = 0;
        while (i < queuedRequestIds.length) {
            bytes32 requestId = queuedRequestIds[i];
            AuthorizedRelease storage auth = authorizations[requestId];

            if (auth.released) {
                _removeFromQueue(i);
                continue;
            }

            uint256 balance = IERC20(auth.asset).balanceOf(address(this));
            if (balance >= auth.amount) {
                auth.released = true;
                IERC20(auth.asset).safeTransfer(auth.user, auth.amount);
                emit QueuedReleaseProcessed(requestId, auth.user, auth.asset, auth.amount);
                _removeFromQueue(i);
            } else {
                i++;
            }
        }
    }

    /// @notice Get the number of queued (unprocessed) withdrawal requests
    function queueLength() external view returns (uint256) {
        return queuedRequestIds.length;
    }

    function _removeFromQueue(uint256 index) internal {
        uint256 lastIndex = queuedRequestIds.length - 1;
        if (index != lastIndex) {
            queuedRequestIds[index] = queuedRequestIds[lastIndex];
        }
        queuedRequestIds.pop();
    }

    function setSpokeVault(address vault) external onlyOwner { spokeVault = vault; }
    function setWithdrawalRegistry(address wr) external onlyOwner { withdrawalRegistry = wr; }
}
