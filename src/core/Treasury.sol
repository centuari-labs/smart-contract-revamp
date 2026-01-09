// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Treasury is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant TOKEN_MANAGER_ROLE =
        keccak256("TOKEN_MANAGER_ROLE");

    mapping(address => mapping(address => uint256)) public balances;

    mapping(address => bool) public supportedToken;

    address public centauriContract;

    event TokenSupportUpdated(address indexed token, bool supported);
    event CentauriContractUpdated(address indexed centauriContract);

    event Deposited(
        address indexed user,
        address indexed token,
        uint256 amount
    );

    event Withdrawn(
        address indexed user,
        address indexed token,
        uint256 amount
    );

    event Repay(address indexed user, address indexed token, uint256 amount);
    event WithdrawLendPosition(
        address indexed user,
        address indexed token,
        uint256 amount
    );
    event Settlement(
        address indexed lender,
        address indexed borrower,
        address indexed token,
        uint256 amount
    );

    event InternalTransfer(
        address indexed from,
        address indexed to,
        address indexed token,
        uint256 amount,
        bytes32 ref
    );

    modifier onlySupportedToken(address token) {
        require(supportedToken[token], "TOKEN_NOT_SUPPORTED");
        _;
    }

    modifier nonZeroAmount(uint256 amount) {
        require(amount > 0, "AMOUNT_ZERO");
        _;
    }

    modifier onlyCentauri() {
        require(msg.sender == centauriContract, "ONLY_CENTAURI");
        _;
    }

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function setSupportedToken(
        address token,
        bool supported
    ) external onlyRole(TOKEN_MANAGER_ROLE) {
        supportedToken[token] = supported;
        emit TokenSupportUpdated(token, supported);
    }

    function setCentauriContract(
        address _centauriContract
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_centauriContract != address(0), "INVALID_ADDRESS");
        centauriContract = _centauriContract;
        emit CentauriContractUpdated(_centauriContract);
    }

    function deposit(
        address token,
        uint256 amount
    )
        external
        nonReentrant
        whenNotPaused
        onlySupportedToken(token)
        nonZeroAmount(amount)
    {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        balances[msg.sender][token] += amount;
        emit Deposited(msg.sender, token, amount);
    }

    function withdraw(
        address token,
        uint256 amount
    )
        external
        nonReentrant
        whenNotPaused
        onlySupportedToken(token)
        nonZeroAmount(amount)
    {
        require(balances[msg.sender][token] >= amount, "INSUFFICIENT_BALANCE");

        balances[msg.sender][token] -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, token, amount);
    }

    function repay(
        address user,
        address token,
        uint256 amount
    )
        external
        nonReentrant
        whenNotPaused
        onlySupportedToken(token)
        onlyCentauri
    {
        require(balances[user][token] >= amount, "INSUFFICIENT_BALANCE");

        balances[user][token] -= amount;
        balances[address(this)][token] += amount;

        emit Repay(user, token, amount);
    }

    function withdrawLendPosition(
        address user,
        address token,
        uint256 amount
    )
        external
        nonReentrant
        whenNotPaused
        onlySupportedToken(token)
        onlyCentauri
    {
        require(
            balances[address(this)][token] >= amount,
            "INSUFFICIENT_BALANCE"
        );

        balances[user][token] += amount;
        balances[address(this)][token] -= amount;

        emit WithdrawLendPosition(user, token, amount);
    }

    function settlement(
        address lender,
        address borrower,
        address token,
        uint256 transferAmount,
        uint256 feeAmount
    )
        external
        nonReentrant
        whenNotPaused
        onlySupportedToken(token)
        onlyCentauri
    {
        // TODO: implement fee logic

        require(
            balances[borrower][token] >= transferAmount,
            "INSUFFICIENT_BALANCE"
        );

        balances[borrower][token] += transferAmount;

        balances[lender][token] -= transferAmount;

        emit Settlement(lender, borrower, token, transferAmount);
    }

    function balanceOf(
        address user,
        address token
    ) external view returns (uint256) {
        return balances[user][token];
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}
