// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Minimal interface for tokens that can be minted by the Faucet (e.g. MockToken)
interface IMintableERC20 {
    function mint(address to, uint256 amount) external;
}

/// @title Faucet
/// @notice Mints mock tokens to recipients when called by authorized operator (backend).
/// @dev Faucet must have the minter role on each MockToken to call mint.
contract Faucet is Ownable {
    struct TokenConfig {
        bool enabled;
        uint256 maxPerRequest; // 0 = no limit
        uint256 cooldown; // seconds, 0 = no cooldown
    }

    // --- Operator role (single operator) ---

    /// @notice Address allowed to call mintTo / batch functions and addToken
    address public operator;

    /// @notice Per-token config: enabled, max per request, cooldown
    mapping(address => TokenConfig) public configOf;

    /// @notice Last mint timestamp per token and recipient (for cooldown)
    mapping(address => mapping(address => uint256)) public lastMintAt;

    /// @notice Maximum tokens allowed in a single batch request (gas abuse guard)
    uint256 public constant MAX_BATCH = 9;

    // --- Events ---

    event OperatorSet(
        address indexed previousOperator,
        address indexed newOperator
    );
    event TokenAdded(
        address indexed token,
        uint256 maxPerRequest,
        uint256 cooldown
    );
    event TokenRemoved(address indexed token);
    event TokenConfigUpdated(
        address indexed token,
        uint256 maxPerRequest,
        uint256 cooldown
    );
    event Minted(
        address indexed token,
        address indexed recipient,
        uint256 amount
    );

    // --- Errors ---

    error InvalidAddress();
    error InvalidAmount();
    error OnlyOperator();
    error TokenNotEnabled();
    error ExceedsMaxPerRequest();
    error CooldownNotElapsed();
    error BatchTooLarge();
    error ArrayLengthMismatch();

    modifier onlyOperator() {
        if (msg.sender != operator) revert OnlyOperator();
        _;
    }

    constructor(address initialOperator) Ownable(msg.sender) {
        if (initialOperator == address(0)) revert InvalidAddress();
        operator = initialOperator;
        emit OperatorSet(address(0), initialOperator);
    }

    // -------------------------------------------------------------------------
    // Operator management -- only owner
    // -------------------------------------------------------------------------

    /// @notice Set the operator address. Only owner.
    function setOperator(address newOperator) external onlyOwner {
        if (newOperator == address(0)) revert InvalidAddress();
        address previous = operator;
        operator = newOperator;
        emit OperatorSet(previous, newOperator);
    }

    // -------------------------------------------------------------------------
    // Token config -- addToken restricted to operator; remove/update owner-only
    // -------------------------------------------------------------------------

    /// @notice Add a token to the faucet. Only operator.
    /// @dev Faucet must already have minter role on the token before calling this.
    function addToken(
        address token,
        uint256 maxPerRequest,
        uint256 cooldown
    ) external onlyOperator {
        if (token == address(0)) revert InvalidAddress();
        configOf[token] = TokenConfig({
            enabled: true,
            maxPerRequest: maxPerRequest,
            cooldown: cooldown
        });
        emit TokenAdded(token, maxPerRequest, cooldown);
    }

    /// @notice Disable a token so it can no longer be minted via faucet. Only owner.
    function removeToken(address token) external onlyOwner {
        if (token == address(0)) revert InvalidAddress();
        configOf[token].enabled = false;
        emit TokenRemoved(token);
    }

    /// @notice Update per-token limits. Only owner.
    function setTokenConfig(
        address token,
        uint256 maxPerRequest,
        uint256 cooldown
    ) external onlyOwner {
        if (token == address(0)) revert InvalidAddress();
        configOf[token].maxPerRequest = maxPerRequest;
        configOf[token].cooldown = cooldown;
        emit TokenConfigUpdated(token, maxPerRequest, cooldown);
    }

    // -------------------------------------------------------------------------
    // Mint -- unchanged single-token entry point
    // -------------------------------------------------------------------------

    /// @notice Mint tokens to a recipient. Only callable by an operator (backend).
    /// @param token  The mintable token address (Faucet must have minter role on it)
    /// @param recipient End-user address to receive the tokens
    /// @param amount Amount to mint (in token units)
    function mintTo(
        address token,
        address recipient,
        uint256 amount
    ) external onlyOperator {
        _mintTo(token, recipient, amount);
    }

    // -------------------------------------------------------------------------
    // Batch mint -- new functionality
    // -------------------------------------------------------------------------

    /// @notice Mint multiple tokens to a recipient in a single transaction. Only operator.
    /// @param tokens    Array of token addresses (max MAX_BATCH elements)
    /// @param amounts   Amount to mint per token, parallel to `tokens`
    /// @param recipient End-user address to receive all tokens
    function mintBatch(
        address[] calldata tokens,
        uint256[] calldata amounts,
        address recipient
    ) external onlyOperator {
        if (tokens.length > MAX_BATCH) revert BatchTooLarge();
        if (tokens.length != amounts.length) revert ArrayLengthMismatch();

        for (uint256 i = 0; i < tokens.length; ) {
            _mintTo(tokens[i], recipient, amounts[i]);
            unchecked {
                ++i;
            }
        }
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    /// @dev Core mint logic, shared by mintTo and mintBatch.
    function _mintTo(
        address token,
        address recipient,
        uint256 amount
    ) internal {
        if (token == address(0) || recipient == address(0))
            revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();

        TokenConfig memory config = configOf[token];
        if (!config.enabled) revert TokenNotEnabled();
        if (config.maxPerRequest != 0 && amount > config.maxPerRequest)
            revert ExceedsMaxPerRequest();
        if (config.cooldown != 0 && lastMintAt[token][recipient] != 0) {
            if (
                block.timestamp < lastMintAt[token][recipient] + config.cooldown
            ) revert CooldownNotElapsed();
        }

        if (config.cooldown != 0) {
            lastMintAt[token][recipient] = block.timestamp;
        }

        IMintableERC20(token).mint(recipient, amount);
        emit Minted(token, recipient, amount);
    }
}
