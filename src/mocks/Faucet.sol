// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Minimal interface for tokens that can be minted by the Faucet (e.g. MockToken)
interface IMintableERC20 {
    function mint(address to, uint256 amount) external;
}

/// @title Faucet
/// @notice Mints mock tokens to recipients when called by the authorized operator (backend).
/// @dev Faucet must have the minter role on each MockToken to call mint. Operator is set by contract owner.
contract Faucet is Ownable {
    struct TokenConfig {
        bool enabled;
        uint256 maxPerRequest; // 0 = no limit
        uint256 cooldown;      // seconds, 0 = no cooldown
    }

    /// @notice Address allowed to call mintTo (e.g. backend)
    address public operator;

    /// @notice Per-token config: enabled, max per request, cooldown
    mapping(address => TokenConfig) public configOf;

    /// @notice Last mint timestamp per token and recipient (for cooldown)
    mapping(address => mapping(address => uint256)) public lastMintAt;

    event OperatorSet(address indexed previousOperator, address indexed newOperator);
    event TokenAdded(address indexed token, uint256 maxPerRequest, uint256 cooldown);
    event TokenRemoved(address indexed token);
    event TokenConfigUpdated(address indexed token, uint256 maxPerRequest, uint256 cooldown);
    event Minted(address indexed token, address indexed recipient, uint256 amount);

    error InvalidAddress();
    error InvalidAmount();
    error OnlyOperator();
    error TokenNotEnabled();
    error ExceedsMaxPerRequest();
    error CooldownNotElapsed();

    constructor() Ownable(msg.sender) {
        operator = msg.sender;
    }

    /// @notice Set the operator (backend) address. Only owner.
    function setOperator(address newOperator) external onlyOwner {
        if (newOperator == address(0)) revert InvalidAddress();
        address previous = operator;
        operator = newOperator;
        emit OperatorSet(previous, newOperator);
    }

    /// @notice Add a token to the faucet. Only owner. Faucet must already have minter role on the token.
    function addToken(address token, uint256 maxPerRequest, uint256 cooldown) external onlyOwner {
        if (token == address(0)) revert InvalidAddress();
        configOf[token] = TokenConfig({enabled: true, maxPerRequest: maxPerRequest, cooldown: cooldown});
        emit TokenAdded(token, maxPerRequest, cooldown);
    }

    /// @notice Disable a token so it can no longer be minted via faucet. Only owner.
    function removeToken(address token) external onlyOwner {
        if (token == address(0)) revert InvalidAddress();
        configOf[token].enabled = false;
        emit TokenRemoved(token);
    }

    /// @notice Update per-token limits. Only owner.
    function setTokenConfig(address token, uint256 maxPerRequest, uint256 cooldown) external onlyOwner {
        if (token == address(0)) revert InvalidAddress();
        configOf[token].maxPerRequest = maxPerRequest;
        configOf[token].cooldown = cooldown;
        emit TokenConfigUpdated(token, maxPerRequest, cooldown);
    }

    /// @notice Mint tokens to a recipient. Only callable by operator (backend).
    /// @param token The mintable token address (Faucet must have minter role on it)
    /// @param recipient End-user address to receive the tokens
    /// @param amount Amount to mint (in token units)
    function mintTo(address token, address recipient, uint256 amount) external {
        if (msg.sender != operator) revert OnlyOperator();
        if (token == address(0) || recipient == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();

        TokenConfig memory config = configOf[token];
        if (!config.enabled) revert TokenNotEnabled();
        if (config.maxPerRequest != 0 && amount > config.maxPerRequest) revert ExceedsMaxPerRequest();
        if (config.cooldown != 0 && lastMintAt[token][recipient] != 0) {
            if (block.timestamp < lastMintAt[token][recipient] + config.cooldown) revert CooldownNotElapsed();
        }

        if (config.cooldown != 0) {
            lastMintAt[token][recipient] = block.timestamp;
        }

        IMintableERC20(token).mint(recipient, amount);
        emit Minted(token, recipient, amount);
    }
}
