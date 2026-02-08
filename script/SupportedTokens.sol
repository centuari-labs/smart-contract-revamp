// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title SupportedTokens
/// @notice Single source of truth for token addresses to support in Treasury.
/// @dev Edit this file to add/remove tokens; DeployCentuariAndTreasury calls setSupportedToken for each.
library SupportedTokens {
    /// @notice Returns the list of token addresses to support in Treasury.
    /// @return Token addresses; add or remove entries below and keep length in sync.
    function getSupportedTokens() public pure returns (address[] memory) {
        // Edit length and addresses as needed (e.g. mainnet USDC, or deploy mock tokens first and paste addresses).
        address[] memory tokens = new address[](0);
        return tokens;
    }
}
