# [LOW] `PushOracle.setOperator` does not reset the price anchor — rotated operator inherits a poisoned `_price1e18`

## Target
`src/core/oracle/PushOracle.sol:97-102`.

## Summary
When governance rotates the operator (e.g., in response to a key compromise), `setOperator` only updates `_operator`. `_price1e18` and `_updatedAt` carry over unchanged. The new operator's first `setPrice` must satisfy the 50% per-update deviation guard against the *previous (possibly poisoned)* anchor. To recover from a 1000× spike, the new operator needs ~10 sequential pushes; in the meantime consumers continue reading the poisoned value (modulo the router's staleness gate).

## Recommended Fix
Add an optional anchor-reset parameter:
```solidity
function setOperator(address newOperator, bool resetAnchor) external onlyOwner {
    if (newOperator == address(0)) revert ZeroAddress();
    address old = _operator;
    _operator = newOperator;
    if (resetAnchor) _updatedAt = 0; // fail-closed via staleness until the next push
    emit OperatorUpdated(old, newOperator);
}
```
With `resetAnchor=true`, the next push is exempt from the deviation gate, and the router's staleness check ensures no stale data flows in the interim.

## Calibration

| field | value |
|-------|-------|
| `severity_post_gate` | Low |
| `confidence_0_100` | 95 |
| `gate_failures` | none |
| `poc_status` | NOT_BUILT |
