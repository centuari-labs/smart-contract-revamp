# [LOW] `OracleRouter.setFeed` does not atomically enforce that `setMaxStaleness` has been called

## Target
`src/core/oracle/OracleRouter.sol:47-52` (`setFeed`), `:80-82` (router fail-close on `maxStaleness == 0`).

## Summary
`setFeed(asset, feed)` writes the feed pointer; `setMaxStaleness(asset, seconds_)` writes the staleness window. They are independent owner-only calls. If governance forgets `setMaxStaleness` (or runs them as separate txs and the first lands alone), `_maxStaleness[asset] == 0` causes `tryGetUsdValue` to fail-closed at line 81. The asset is silently unpriced.

This is fail-closed (safe) but operationally surprising: every newly-registered asset is a "dead" feed until configured. The router's design already rejects `setMaxStaleness(asset, 0)` (SC-3, line 60) which suggests this is intentional, but the atomic enforcement is missing.

## Recommended Fix
Either combine the two into a single atomic registration:
```solidity
function setFeed(address asset, address feed, uint256 maxSeconds) external onlyOwner {
    if (asset == address(0)) revert ZeroAddress();
    if (feed != address(0) && maxSeconds == 0) revert ZeroStaleness();
    ...
}
```

OR require the staleness be set before `setFeed` succeeds:
```solidity
function setFeed(address asset, address feed) external onlyOwner {
    if (asset == address(0)) revert ZeroAddress();
    if (feed != address(0) && _maxStaleness[asset] == 0) revert ZeroStaleness();
    ...
}
```

The second variant preserves the current signature.

## Calibration

| field | value |
|-------|-------|
| `severity_post_gate` | Low |
| `confidence_0_100` | 100 |
| `gate_failures` | none |
| `poc_status` | NOT_BUILT (operational hygiene) |
