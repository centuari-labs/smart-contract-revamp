// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IPriceOracle
/// @notice Protocol-neutral USD valuation seam consumed by the RiskModule.
/// @dev Provider-agnostic by design: the RiskModule depends ONLY on this
///      interface and never on any vendor's price-feed type. Implementations
///      (e.g. `OracleRouter`) resolve a per-asset `IPriceFeed` source — real
///      Chainlink feeds, an operator-pushed `PushOracle`, or a future in-house
///      oracle — behind this boundary, so swapping providers never touches the
///      RiskModule.
///
///      MUST be non-reverting: a missing / stale / invalid price returns
///      `(0, false)` so the RiskModule can fail-closed without bubbling a
///      revert through the `IRiskModule` view callers (which must not revert).
interface IPriceOracle {
    /// @notice USD value (1e18-scaled) of `amount` base units of `asset`.
    /// @param asset The token whose holdings are being valued
    /// @param amount The amount in the token's own base units (decimals)
    /// @return value1e18 USD value scaled to 1e18 ($1.00 == 1e18); 0 if not ok
    /// @return ok False if the asset is unpriced, the source is stale, or any
    ///         read failed — callers MUST treat false as fail-closed
    function tryGetUsdValue(address asset, uint256 amount) external view returns (uint256 value1e18, bool ok);
}
