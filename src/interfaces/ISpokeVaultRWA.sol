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
    function deposit(address asset, uint256 amount) external payable;

    /// @notice NC-02 FIX: releaseLiquidation is now internal.
    /// @dev All liquidation releases go through lzReceive() which verifies:
    ///      (1) msg.sender == layerZeroEndpoint
    ///      (2) srcEid == hubChainEid
    ///      (3) sender == hubLiquidationEngine
    ///      The old external releaseLiquidation() only checked (1), leaving (2) and (3) unverified.
    ///      Security Invariant #3 now fully enforced.

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
