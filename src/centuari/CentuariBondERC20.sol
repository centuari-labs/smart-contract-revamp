// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title CentuariBondERC20
/// @notice ERC20 token representing a lender's bond position in a specific market
/// @dev Each bond token is unique to a (loanToken, maturity) pair.
///      Only the Centuari contract (minter) can mint tokens.
///      Tokens are fully transferable.
contract CentuariBondERC20 is ERC20 {
    // ============ Errors ============

    /// @notice Thrown when caller is not the minter
    error OnlyMinter();

    // ============ Immutable Storage ============

    /// @notice The address authorized to mint tokens (Centuari contract)
    address public immutable minter;

    /// @notice The underlying loan token address
    address public immutable loanToken;

    /// @notice The maturity timestamp for this bond
    uint256 public immutable maturity;

    /// @notice The decimals of the underlying loan token
    uint8 private immutable _decimals;

    // ============ Constructor ============

    /// @notice Creates a new bond token
    /// @param name_ The token name (e.g., "CBT USDC 1 Jan 2025")
    /// @param symbol_ The token symbol (e.g., "CBT-USDC-1JAN25")
    /// @param minter_ The address authorized to mint (Centuari contract)
    /// @param loanToken_ The underlying loan token address
    /// @param maturity_ The maturity timestamp
    constructor(
        string memory name_,
        string memory symbol_,
        address minter_,
        address loanToken_,
        uint256 maturity_
    ) ERC20(name_, symbol_) {
        minter = minter_;
        loanToken = loanToken_;
        maturity = maturity_;

        // Try to get decimals from loan token, default to 18 if not available
        try IERC20Metadata(loanToken_).decimals() returns (uint8 dec) {
            _decimals = dec;
        } catch {
            _decimals = 18;
        }
    }

    // ============ Modifiers ============

    /// @notice Restricts function access to the minter
    modifier onlyMinter() {
        if (msg.sender != minter) revert OnlyMinter();
        _;
    }

    // ============ External Functions ============

    /// @notice Mint tokens to an address
    /// @dev Only callable by the minter (Centuari contract)
    /// @param to The address to mint tokens to
    /// @param amount The amount of tokens to mint
    function mint(address to, uint256 amount) external onlyMinter {
        _mint(to, amount);
    }

    /// @notice Burn tokens from caller's balance
    /// @dev Anyone can burn their own tokens (for future redemption)
    /// @param amount The amount of tokens to burn
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /// @notice Burn tokens from an address (requires approval)
    /// @dev Caller must have allowance from the account
    /// @param account The address to burn tokens from
    /// @param amount The amount of tokens to burn
    function burnFrom(address account, uint256 amount) external {
        _spendAllowance(account, msg.sender, amount);
        _burn(account, amount);
    }

    // ============ View Functions ============

    /// @notice Returns the number of decimals
    /// @dev Matches the decimals of the underlying loan token
    /// @return The number of decimals
    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}

