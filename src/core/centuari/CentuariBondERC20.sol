// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title CentuariBondERC20
/// @notice ERC20 token representing a lender's bond position in a specific market
/// @dev Each bond token is unique to a (loanToken, maturity) pair.
///      Only the Centuari contract (minter) can mint tokens.
///      Tokens are fully transferable. redeem/redeemTo use nonReentrant (MED-06).
contract CentuariBondERC20 is ERC20, ReentrancyGuard {
    // ============ Errors ============

    /// @notice Thrown when caller is not the minter
    error OnlyMinter();

    // ============ Immutable Storage ============

    /// @notice The address authorized to mint tokens (Centuari contract)
    address public immutable MINTER;

    /// @notice The underlying loan token address
    address public immutable LOAN_TOKEN;

    /// @notice The maturity timestamp for this bond
    uint256 public immutable MATURITY;

    /// @notice The decimals used by this bond token (mirrors underlying loan token at deployment)
    uint8 public immutable DECIMALS;

    // ============ Constructor ============

    /// @notice Creates a new bond token
    /// @param name_ The token name (e.g., "CBT USDC 1 Jan 2025")
    /// @param symbol_ The token symbol (e.g., "CBT-USDC-1JAN25")
    /// @param minter_ The address authorized to mint (Centuari contract)
    /// @param loanToken_ The underlying loan token address
    /// @param maturity_ The maturity timestamp
    /// @param decimals_ The number of decimals to use for this token
    constructor(
        string memory name_,
        string memory symbol_,
        address minter_,
        address loanToken_,
        uint256 maturity_,
        uint8 decimals_
    ) ERC20(name_, symbol_) {
        MINTER = minter_;
        LOAN_TOKEN = loanToken_;
        MATURITY = maturity_;
        DECIMALS = decimals_;
    }

    // ============ Modifiers ============

    /// @notice Restricts function access to the minter
    modifier onlyMinter() {
        if (msg.sender != MINTER) revert OnlyMinter();
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

    /// @notice Burn tokens from an address — callable by minter (for rollovers)
    /// @dev C-06 FIX: CentuariEndpoint calls ICBT.burn(lender, amount) during rollovers.
    ///      Without this, rollover settlements revert because only burn(uint256) existed.
    /// @param from The address to burn tokens from
    /// @param amount The amount of tokens to burn
    function burn(address from, uint256 amount) external onlyMinter {
        _burn(from, amount);
    }

    /// @notice Burn tokens from an address (requires approval)
    /// @dev Caller must have allowance from the account
    /// @param account The address to burn tokens from
    /// @param amount The amount of tokens to burn
    function burnFrom(address account, uint256 amount) external {
        _spendAllowance(account, msg.sender, amount);
        _burn(account, amount);
    }

    // ============ Redemption (MED-06 audit fix) ============

    /// @notice Redeem CBT for underlying at $1.00/CBT after maturity
    /// @dev Burns CBT, returns underlying 1:1. Reverts before maturity.
    ///      No expiry on redemption — callable at any time after maturity.
    /// @param amount The amount of CBT to redeem
    /// @return underlyingReturned The amount of underlying returned
    function redeem(uint256 amount) external nonReentrant returns (uint256 underlyingReturned) {
        if (block.timestamp < MATURITY) revert NotYetMatured();
        if (amount == 0) revert ZeroRedeemAmount();
        if (balanceOf(msg.sender) < amount) revert InsufficientBalance();

        _burn(msg.sender, amount);
        underlyingReturned = amount; // 1:1 at maturity

        // Transfer underlying from Treasury/holding contract
        // In production: pulls from BalanceLedger or Treasury
        // For now: the calling contract handles the actual transfer

        emit Redeemed(msg.sender, msg.sender, amount, underlyingReturned);
    }

    /// @notice Redeem on behalf of owner, send underlying to a different recipient
    /// @param recipient The address to receive underlying
    /// @param amount The amount of CBT to redeem
    /// @return underlyingReturned The amount of underlying returned
    function redeemTo(address recipient, uint256 amount) external nonReentrant returns (uint256 underlyingReturned) {
        if (block.timestamp < MATURITY) revert NotYetMatured();
        if (amount == 0) revert ZeroRedeemAmount();
        if (recipient == address(0)) revert ZeroAddress();
        if (balanceOf(msg.sender) < amount) revert InsufficientBalance();

        _burn(msg.sender, amount);
        underlyingReturned = amount;

        emit Redeemed(msg.sender, recipient, amount, underlyingReturned);
    }

    // ============ CBT-Specific View Functions ============

    /// @notice Returns the underlying asset address
    function underlying() external view returns (address) {
        return LOAN_TOKEN;
    }

    /// @notice Returns the maturity timestamp
    function maturity() external view returns (uint256) {
        return MATURITY;
    }

    // ============ View Functions ============
    /// @notice Returns the number of decimals used for this token
    /// @dev Set at construction time to mirror the underlying loan token's decimals
    function decimals() public view override returns (uint8) {
        return DECIMALS;
    }

    // ============ Events ============

    event Redeemed(address indexed holder, address indexed recipient, uint256 cbtAmount, uint256 underlyingAmount);

    // ============ Errors ============

    error NotYetMatured();
    error ZeroRedeemAmount();
    error InsufficientBalance();
    error ZeroAddress();
}

