# [MEDIUM] `PushOracle.setBounds` does not re-validate stored price

## Target
`src/core/oracle/PushOracle.sol:105-110` (`setBounds`) and `:121-123` (`latestPriceUsd`).

## Summary
`setBounds(min, max)` only validates the new bounds against each other (`minPrice_ == 0 || minPrice_ >= maxPrice_`). It does not re-validate that the currently-stored `_price1e18` falls inside the new bounds. After narrowing, `latestPriceUsd()` keeps returning the (now out-of-bounds) `_price1e18`, while the next `setPrice` reverts with `PriceOutOfBounds`. The oracle is effectively frozen at a value the bounds reject.

## Detail
- **Lines:** 105-110 (`setBounds`), 121-123 (`latestPriceUsd` reads `_price1e18` without re-checking).
- **Category:** Governance setter / oracle consistency.
- **Root cause:** asymmetry between `setBounds` and `setPrice`.

```solidity
function setBounds(uint256 minPrice_, uint256 maxPrice_) external onlyOwner {
    if (minPrice_ == 0 || minPrice_ >= maxPrice_) revert InvalidBounds();
    _minPrice = minPrice_;
    _maxPrice = maxPrice_;
    emit PriceBoundsUpdated(minPrice_, maxPrice_);
}
```

## Impact
Operational footgun, not direct exploit:
- Owner attempts emergency response (narrow bounds to lock out compromised operator). Bounds narrow, but the existing in-storage price keeps flowing to consumers. Defense fires only on the next push, which the same compromised operator can simply refuse to make.
- Owner accidentally narrows bounds excluding the current price. Oracle stays "alive" returning an OOB value to RiskModule/LiquidationEngine.

## Recommended Fix
```solidity
function setBounds(uint256 minPrice_, uint256 maxPrice_) external onlyOwner {
    if (minPrice_ == 0 || minPrice_ >= maxPrice_) revert InvalidBounds();
    _minPrice = minPrice_;
    _maxPrice = maxPrice_;
    // If the existing price is now out of bounds, zero its timestamp so the
    // OracleRouter staleness gate fail-closes until a fresh in-bounds push.
    if (_updatedAt != 0 && (_price1e18 < minPrice_ || _price1e18 > maxPrice_)) {
        _updatedAt = 0; // fail-closed via staleness
    }
    emit PriceBoundsUpdated(minPrice_, maxPrice_);
}
```

This makes "narrow the bounds" a one-step emergency: the price freezes, and the staleness gate at `OracleRouter.sol:80-82` returns `(0, false)` until a fresh push.

## Calibration

| field | value |
|-------|-------|
| `severity_post_gate` | Medium |
| `confidence_0_100` | 90 |
| `single_strongest_reject` | "Owner will manually push a new in-bounds price after narrowing." — counter: this requires a second tx and assumes the operator is trustworthy; in an emergency response that's exactly the question. |
| `gate_failures` | none |
| `poc_status` | NOT_BUILT |
