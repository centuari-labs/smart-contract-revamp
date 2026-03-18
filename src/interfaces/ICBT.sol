// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ICBT
/// @notice Full interface for Centuari Bond Token (CBT) - ERC20 representing lender positions
/// @dev One CBT contract per (asset, maturity) pair. Redeemable at $1.00/CBT at maturity.
///      CBT is a standard ERC-20 with additional Centuari-specific functions.
interface ICBT {
    // ============ Standard ERC-20 (inherited, listed for completeness) ============

    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);

    // ============ CBT-Specific (read-only state) ============

    /// @notice Returns the underlying asset address (e.g., USDC)
    function underlying() external view returns (address);

    /// @notice Returns the maturity timestamp (Unix seconds)
    function maturity() external view returns (uint256);

    // ============ Redemption ============

    /// @notice Redeem CBT for underlying at $1.00/CBT after maturity
    /// @dev Burns CBT, returns underlying. Reverts if block.timestamp < maturity.
    ///      No expiry on redemption — callable at any time after maturity.
    ///      nonReentrant required (MED-06 audit fix).
    /// @param amount The amount of CBT to redeem
    /// @return underlyingReturned The amount of underlying asset returned
    function redeem(uint256 amount) external returns (uint256 underlyingReturned);

    /// @notice Redeem on behalf of owner, send underlying to a different recipient
    /// @dev nonReentrant required (MED-06 audit fix).
    /// @param recipient The address to receive the underlying asset
    /// @param amount The amount of CBT to redeem
    /// @return underlyingReturned The amount of underlying asset returned
    function redeemTo(address recipient, uint256 amount) external returns (uint256 underlyingReturned);

    // ============ Controlled Access (CentuariEndpoint only) ============

    /// @notice Mint CBT tokens — called during settlement (new match)
    /// @dev Amount validated ±1 wei on-chain by CentuariEndpoint
    /// @param to The address to mint to
    /// @param amount The amount to mint
    function mint(address to, uint256 amount) external;

    /// @notice Burn CBT tokens — called during rollover (burn old CBT)
    /// @dev External burn is CentuariEndpoint-only. User burns go through redeem().
    /// @param from The address to burn from
    /// @param amount The amount to burn
    function burn(address from, uint256 amount) external;

    // ============ Events ============

    event Redeemed(address indexed holder, address indexed recipient, uint256 cbtAmount, uint256 underlyingAmount);

    // ============ Errors ============

    error NotYetMatured();
    error InsufficientBalance();
    error ZeroAddress();
    error ZeroAmount();
    error Unauthorized();
}
