// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ICentuariCallback
/// @notice Callback interface for external protocols integrating with CentuariRouter
/// @dev Implement this to receive CBT fill notifications from CentuariRouter.
///      Called with 200,000 gas limit. Keep implementation minimal.
interface ICentuariCallback {
    /// @notice Called by CentuariRouter when a lend/borrow intent is filled
    /// @param intentId The filled intent identifier
    /// @param cbtAddress The CBT contract address
    /// @param cbtAmount The amount of CBT minted
    /// @param filledAmount The matched principal amount
    /// @param rateBPS The actual matched rate in basis points
    function onIntentFilled(
        bytes32 intentId,
        address cbtAddress,
        uint256 cbtAmount,
        uint256 filledAmount,
        uint256 rateBPS
    ) external;
}
