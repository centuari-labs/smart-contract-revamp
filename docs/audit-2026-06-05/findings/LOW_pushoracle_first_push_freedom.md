# [LOW] `PushOracle` first-push exemption + `[1, MAX]` defaults allow arbitrary anchor on initial deploy

## Target
`src/core/oracle/PushOracle.sol:84` (first-push exemption), `:62-75` (constructor defaults).

## Summary
The first `setPrice` after deploy (when `_updatedAt == 0`) is exempt from the 50% deviation guard. Combined with constructor defaults `_minPrice = 1`, `_maxPrice = type(uint256).max`, the operator's very first push can be any non-zero value. Subsequent pushes are then bounded to ±50% of that first value. A fat-fingered or compromised first push locks the oracle's neighborhood until governance widens deviation or bounds.

## Recommended Fix
Push the initial price *atomically* with `setFeed` and `setBounds` in the same deploy transaction. The deploy script orchestration must include this step. Alternatively, the constructor can accept and set an initial price + bounds in one atomic step, eliminating the gap entirely.

## Calibration

| field | value |
|-------|-------|
| `severity_post_gate` | Low |
| `confidence_0_100` | 95 |
| `gate_failures` | none |
| `poc_status` | NOT_BUILT |
