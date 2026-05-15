// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title MockToken
/// @notice ERC20 token for testnet use with configurable name, symbol, and decimals
/// @dev Mintable by accounts with MINTER_ROLE; deployer gets DEFAULT_ADMIN_ROLE and MINTER_ROLE
contract MockToken is ERC20, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    uint8 private _decimals;

    /// @notice Creates a new mock token
    /// @param name_ Token name (e.g. "USD Coin")
    /// @param symbol_ Token symbol (e.g. "USDC")
    /// @param decimals_ Number of decimals (e.g. 6 for USDC)
    /// @param initialSupply_ Initial supply to mint to deployer (use 0 for none)
    constructor(string memory name_, string memory symbol_, uint8 decimals_, uint256 initialSupply_)
        ERC20(name_, symbol_)
    {
        _decimals = decimals_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        if (initialSupply_ > 0) {
            _mint(msg.sender, initialSupply_);
        }
    }

    /// @inheritdoc ERC20
    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    /// @notice Mint tokens to an address (caller must have MINTER_ROLE)
    /// @param to Recipient address
    /// @param amount Amount to mint (in token units, i.e. already scaled by 10^decimals)
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }
}
