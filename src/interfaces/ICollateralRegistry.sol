// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ICollateralRegistry
/// @notice Manages RWA attestation processing from spoke chains via LayerZero
/// @dev Receives attestation messages, validates replay protection, creates collateral positions
interface ICollateralRegistry {
    // ============ Attestation Processing ============

    /// @notice Process an attestation from a spoke chain
    /// @dev Validates: attestation not replayed, timestamp monotonically increasing per (user, asset, chainId)
    /// @param attestationId Unique attestation identifier
    /// @param user The user who deposited on spoke
    /// @param asset The collateral asset address
    /// @param amount The amount deposited
    /// @param attestationTimestamp Timestamp of the attestation
    /// @param sourceChainId The spoke chain ID
    function processAttestation(
        bytes32 attestationId,
        address user,
        address asset,
        uint256 amount,
        uint256 attestationTimestamp,
        uint256 sourceChainId
    ) external;

    /// @notice Refresh collateral values with current prices (keeper job)
    /// @param users Array of user addresses to refresh
    function refreshCollateralValues(address[] calldata users) external;

    /// @notice Update cached USD value for a collateral position
    /// @param user The user address
    /// @param asset The collateral asset
    /// @param newUsdValue The new USD value
    function updateCollateralValue(address user, address asset, uint256 newUsdValue) external;

    // ============ View Functions ============

    /// @notice Check if an attestation has been processed
    function isAttestationUsed(bytes32 attestationId) external view returns (bool);

    /// @notice Get last attestation timestamp for (user, asset, chainId)
    function getLastAttestationTs(
        address user,
        address asset,
        uint256 sourceChainId
    ) external view returns (uint256);

    // ============ Events ============

    event AttestationProcessed(
        bytes32 indexed attestationId,
        address indexed user,
        address indexed asset,
        uint256 amount,
        uint256 sourceChainId
    );
    event CollateralValueUpdated(address indexed user, address indexed asset, uint256 newUsdValue);

    // ============ Errors ============

    error Unauthorized();
    error AttestationAlreadyUsed(bytes32 attestationId);
    error AttestationTooOld(uint256 provided, uint256 lastAccepted);
    error ZeroAddress();
    error ZeroAmount();
}
