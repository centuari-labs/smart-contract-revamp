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

import {ITreasury} from "../interfaces/ITreasury.sol";
import {CentuariBondERC20} from "./centuari/CentuariBondERC20.sol";

contract Treasury is AccessControl, Pausable, ReentrancyGuard, ITreasury {
    using SafeERC20 for IERC20;

    bytes32 public constant TOKEN_MANAGER_ROLE =
        keccak256("TOKEN_MANAGER_ROLE");

    //@todo : cbt assets should can also be withdrawn from the treasury

    //@note : should use uuid from the account id instead of address
    //@note : should use uuid from the assets id instead of address
    mapping(address => mapping(address => uint256)) public balances;

    //@note : should use uuid from the assets id instead of address
    mapping(address => bool) public supportedToken;

    address internal operator;

    address public centuariContract;

    modifier onlySupportedToken(address token) {
        if (!supportedToken[token]) revert Unauthorized();
        _;
    }

    modifier nonZeroAmount(uint256 amount) {
        if (amount == 0) revert InvalidAmount();
        _;
    }

    modifier onlyCentuari() {
        if (centuariContract == address(0)) revert Unauthorized();
        if (msg.sender != centuariContract) revert Unauthorized();
        _;
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert Unauthorized();
        _;
    }

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function registerBondToken(
        address bondToken
    ) external override onlyCentuari {
        if (bondToken == address(0)) revert ZeroAddress();
        if (!supportedToken[bondToken]) {
            supportedToken[bondToken] = true;
            emit TokenSupportUpdated(bondToken, true);
        }
    }

    function setSupportedToken(
        address token,
        bool supported
    ) external override onlyRole(TOKEN_MANAGER_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        supportedToken[token] = supported;
        emit TokenSupportUpdated(token, supported);
    }

    function setCentuariContract(
        address _centuariContract
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_centuariContract == address(0)) revert ZeroAddress();
        centuariContract = _centuariContract;
        emit CentuariContractUpdated(_centuariContract);
    }

    /// @notice Deposit tokens to treasury
    function deposit(
        address token,
        uint256 amount
    )
        external
        override
        nonReentrant
        whenNotPaused
        onlySupportedToken(token)
        nonZeroAmount(amount)
    {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        balances[msg.sender][token] += amount;
        emit Deposited(msg.sender, token, amount);
    }

    //@todo : add access control only operator
    function withdraw(
        address token,
        address to,
        uint256 amount
    )
        external
        override
        nonReentrant
        whenNotPaused
        onlySupportedToken(token)
        nonZeroAmount(amount)
        onlyOperator
    {
        if (balances[to][token] < amount) revert InsufficientFunds();

        balances[to][token] -= amount;
        IERC20(token).safeTransfer(to, amount);

        emit Withdrawn(to, token, amount);
    }

    function repay(
        address user,
        address token,
        uint256 amount
    )
        external
        override
        nonReentrant
        whenNotPaused
        onlySupportedToken(token)
        onlyCentuari
        nonZeroAmount(amount)
    {
        if (user == address(0)) revert ZeroAddress();
        if (balances[user][token] < amount) revert InsufficientFunds();

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
        override
        nonReentrant
        whenNotPaused
        onlySupportedToken(token)
        onlyCentuari
        nonZeroAmount(amount)
    {
        if (user == address(0)) revert ZeroAddress();
        if (balances[address(this)][token] < amount) revert InsufficientFunds();

        balances[user][token] += amount;
        balances[address(this)][token] -= amount;

        emit WithdrawLendPosition(user, token, amount);
    }

    function recordBondMint(
        address user,
        address bondToken,
        uint256 amount
    )
        external
        override
        nonReentrant
        whenNotPaused
        onlySupportedToken(bondToken)
        onlyCentuari
        nonZeroAmount(amount)
    {
        if (user == address(0)) revert ZeroAddress();
        balances[user][bondToken] += amount;
    }

    function burnBondForUser(
        address user,
        address bondToken,
        uint256 amount
    )
        external
        override
        nonReentrant
        whenNotPaused
        onlySupportedToken(bondToken)
        onlyCentuari
        nonZeroAmount(amount)
    {
        if (user == address(0)) revert ZeroAddress();
        if (balances[user][bondToken] < amount) revert InsufficientFunds();

        balances[user][bondToken] -= amount;
        CentuariBondERC20(bondToken).burn(amount);
    }

    /// @inheritdoc ITreasury
    function settle(
        address loanToken,
        address from,
        address to,
        uint256 amount,
        uint256 lenderSettlementFee,
        uint256 borrowerSettlementFee,
        uint256 lenderTradeFee,
        uint256 borrowerTradeFee
    )
        external
        override
        nonReentrant
        whenNotPaused
        onlySupportedToken(loanToken)
        onlyCentuari
    {
        // Validate inputs
        if (from == address(0)) revert ZeroAddress();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();

        // Calculate total lender deduction: principal + all lender fees
        uint256 totalLenderFee = lenderSettlementFee + lenderTradeFee;
        uint256 totalFromLender = amount + totalLenderFee;

        // Check lender has sufficient balance for principal + fees
        if (balances[from][loanToken] < totalFromLender)
            revert InsufficientFunds();

        // Deduct principal + fees from lender
        balances[from][loanToken] -= totalFromLender;

        // Credit full principal to borrower (no fee deduction)
        balances[to][loanToken] += amount;

        // Collect lender fees as protocol revenue
        if (totalLenderFee > 0) {
            balances[address(this)][loanToken] += totalLenderFee;
        }

        // Deduct borrower fees from borrower's balance
        uint256 totalBorrowerFee = borrowerSettlementFee + borrowerTradeFee;
        if (totalBorrowerFee > 0) {
            if (balances[to][loanToken] < totalBorrowerFee)
                revert InsufficientFunds();
            balances[to][loanToken] -= totalBorrowerFee;
            balances[address(this)][loanToken] += totalBorrowerFee;
        }

        // Emit settlement event
        emit SettlementExecuted(
            loanToken,
            from,
            to,
            amount,
            lenderSettlementFee,
            borrowerSettlementFee,
            lenderTradeFee,
            borrowerTradeFee
        );
    }

    /// @inheritdoc ITreasury
    function protocolFeeBalance(
        address token
    ) external view override returns (uint256) {
        return balances[address(this)][token];
    }

    /// @inheritdoc ITreasury
    function withdrawProtocolFees(
        address token,
        address recipient,
        uint256 amount
    )
        external
        override
        nonReentrant
        whenNotPaused
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();
        if (balances[address(this)][token] < amount) revert InsufficientFunds();

        balances[address(this)][token] -= amount;
        IERC20(token).safeTransfer(recipient, amount);

        emit ProtocolFeesWithdrawn(token, recipient, amount);
    }

    function balanceOf(
        address user,
        address token
    ) external view override returns (uint256) {
        return balances[user][token];
    }

    function setOperator(
        address newOperator
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newOperator == address(0)) revert ZeroAddress();
        operator = newOperator;
        emit OperatorUpdated(operator, newOperator);
    }

    function pause() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function getOperator() external view returns (address) {
        return operator;
    }
}
