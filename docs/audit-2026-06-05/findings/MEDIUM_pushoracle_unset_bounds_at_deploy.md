# [MEDIUM] `PushOracle` deploys with permissive defaults and no deploy-script `setBounds`/`setMaxDeviationBps` call

## Target
`src/core/oracle/PushOracle.sol` constructor (lines 62-75) + project deploy scripts under `script/`.

## Summary
`PushOracle` constructor sets `_minPrice = 1` (1 wei in 1e18 USD scaling = `$1e-18`) and `_maxPrice = type(uint256).max`. No project deploy script (`DeployRiskModule.s.sol`, `RedeployPushOracles.s.sol`, `ConfigureRiskModule.s.sol`) calls `setBounds(asset, ...)` to tighten these per asset before the feed is consumed via `OracleRouter.setFeed`. Until governance manually tightens, the absolute bounds gate is inactive.

Verification:
```
grep -rn "setBounds\|setMaxDeviationBps" script/   # zero matches
grep -rn "setBounds\|setMaxDeviationBps" src/core/oracle/  # only PushOracle.sol declarations
```

## Detail
- **Lines:** PushOracle constructor 62-75, deploy scripts 67-72 (DeployRiskModule) and 38-50 (RedeployPushOracles).
- **Category:** Deployment / configuration hygiene; defense-in-depth shipped inactive.
- **Root cause:** the `[_minPrice, _maxPrice]` bounds are second-line-of-defense against operator key compromise. The first line (per-update 50% deviation guard, line 88) is itself defeated by same-tx multi-call (see HIGH_pushoracle_deviation_guard_multicall.md). With the second line equivalent to `[1, ∞]`, both defenses are effectively absent.

## Impact
Operator key compromise → unbounded blast radius. See cross-reference HIGH finding for the exploit chain. This finding is the *systemic* cause; the multi-call finding is one of several mechanisms it enables.

## Recommended Fix
Either:
- Make the constructor require non-trivial bounds (callers must pass `minPrice_`, `maxPrice_` at deploy), OR
- Add per-feed acceptance assertions in `OracleRouter.setFeed`: reject feeds whose `_maxPrice == type(uint256).max` or `_minPrice <= 1`, OR
- Mandate in the deploy script (run-all.sh / deploy-hardened.sh) that `PushOracle.setBounds(asset, sensible_min, sensible_max)` runs immediately after deploy and before any `OracleRouter.setFeed` registration.

Option 3 is the lowest-code-diff and matches the existing operator-hygiene pattern in the deploy orchestration.

## Calibration

| field | value |
|-------|-------|
| `severity_post_gate` | Medium |
| `confidence_0_100` | 90 |
| `single_strongest_reject` | "Owner is trusted to tighten post-deploy." — counter: relying on a manual post-deploy step for a critical safety bound is the same kind of opt-in safety that historically gets forgotten. Even one missed asset is one too many. |
| `smallest_falsifier` | grep above (already done). |
| `gate_failures` | none |
| `poc_status` | NOT_BUILT (config verification, not exploit) |
