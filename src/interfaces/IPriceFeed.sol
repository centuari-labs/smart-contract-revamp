// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IPriceFeed
/// @notice Protocol-neutral per-asset price source.
/// @dev The single seam every price provider implements — a Chainlink adapter
///      (`ChainlinkPriceFeed`), an operator-pushed `PushOracle`, or a future
///      in-house oracle. Each implementation normalizes its own native decimals
///      so the returned price is always 1e18-scaled USD per WHOLE token. The
///      `OracleRouter` reads only this interface, so no vendor type leaks into
///      the router or the RiskModule.
interface IPriceFeed {
    /// @notice Latest USD price of one whole token, scaled to 1e18.
    /// @return price1e18 USD per whole token, 1e18-scaled ($1.00 == 1e18);
    ///         0 signals "no valid price" (the router fail-closes)
    /// @return updatedAt Unix seconds the price was last updated (for the
    ///         router's per-asset staleness check)
    function latestPriceUsd() external view returns (uint256 price1e18, uint256 updatedAt);
}
