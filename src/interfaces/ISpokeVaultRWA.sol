// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ISpokeVaultRWA
/// @notice Spoke chain vault for compliance-restricted RWA tokens
/// @dev Locks RWAs permanently while position is active. Sends attestation to hub via LayerZero.
///      Releases only on verified LayerZero message from hub LiquidationEngine (Invariant #3).
interface ISpokeVaultRWA {
    /// @notice Deposit RWA token — locks it and sends attestation to hub
    /// @dev Requires: user approved by issuer KYC whitelist
    /// @param asset The RWA token address
    /// @param amount The amount to deposit
    function deposit(address asset, uint256 amount) external;

    /// @notice Release RWA on liquidation command from hub
    /// @dev ONLY callable via LayerZero from hub LiquidationEngine (Security Invariant #3)
    /// @param user The user whose collateral to release
    /// @param asset The RWA token to release
    /// @param amount The amount to release
    /// @param liquidator The approved liquidator to receive tokens
    function releaseLiquidation(
        address user,
        address asset,
        uint256 amount,
        address liquidator
    ) external;

    /// @notice Report that an asset has been frozen by the issuer
    /// @dev Anyone can call — verified by checking transferability
    /// @param asset The frozen asset
    function reportFrozen(address asset) external;

    // ============ Events ============

    event RWADeposited(address indexed user, address indexed asset, uint256 amount);
    event AttestationSent(address indexed user, address indexed asset, uint256 amount, bytes32 attestationId);
    event LiquidationReleased(address indexed user, address indexed asset, uint256 amount, address indexed liquidator);
    event AssetFrozenReported(address indexed asset);

    // ============ Errors ============

    error Unauthorized();
    error OnlyLayerZeroFromHub();
    error AssetFrozen(address asset);
    error ZeroAmount();
    error KYCRequired(address user);
}
