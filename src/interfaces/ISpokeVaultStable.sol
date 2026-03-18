// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ISpokeVaultStable
/// @notice Spoke chain vault for stablecoins (USDC, USDT, USDe)
/// @dev Locks stablecoins, bridges excess to hub via LayerZero OFT / CCTP.
///      Maintains withdrawal liquidity buffer (HIGH_WATER_MARK / LOW_WATER_MARK).
interface ISpokeVaultStable {
    /// @notice User deposits stablecoin to spoke vault
    function deposit(address asset, uint256 amount) external;

    /// @notice User withdraws stablecoin from spoke vault
    function withdraw(address asset, uint256 amount) external;

    /// @notice Sweeper bridges excess to hub (called by Sweeper or Gelato)
    function sweepToHub(address asset, uint256 amount, bytes calldata bridgePayload) external;

    /// @notice Receive replenishment from hub
    function receiveFromHub(address asset, uint256 amount) external;

    /// @notice Get current balance for an asset
    function getBalance(address asset) external view returns (uint256);

    /// @notice Get target buffer level for an asset
    function getBufferTarget(address asset) external view returns (uint256);

    // ============ Events ============

    event Deposited(address indexed user, address indexed asset, uint256 amount);
    event Withdrawn(address indexed user, address indexed asset, uint256 amount);
    event SweptToHub(address indexed asset, uint256 amount);
    event ReceivedFromHub(address indexed asset, uint256 amount);

    // ============ Errors ============

    error Unauthorized();
    error InsufficientBuffer();
    error ZeroAmount();
    error UnsupportedAsset();
}
