# [HIGH] `PushOracle` deviation guard defeated by same-tx multi-call

## Bounty Platform Submission Info
- **Target:** `src/core/oracle/PushOracle.sol`
- **Severity Level:** High
- **Bug Classification:** Oracle defense-in-depth bypass (operator key compromise blast-radius unbounded)

## Summary
`PushOracle.setPrice` enforces a per-call deviation bound (default 50%) against the previously stored price, then overwrites the stored price. There is no per-block, per-tx, or per-time-window rate limit. An attacker controlling the operator key can chain N sequential `setPrice` calls inside a single transaction, walking the price by 50% on each step and compounding to a 99% drop in fewer than 7 calls.

The defense is documented (`PushOracle.sol:21-24` — "SC-2 hardening") as a mitigation for operator-key compromise. The same-tx multi-call defeats it entirely.

## Detail
- **Contract:** `src/core/oracle/PushOracle.sol`
- **Function:** `setPrice(uint256 price1e18)`
- **Lines:** 80-94
- **Category:** Oracle defense-in-depth bypass
- **Root cause:** State writes `_price1e18 = price1e18; _updatedAt = block.timestamp;` happen on every call. The deviation check on line 88 reads only the just-overwritten `prev`. Successive calls in the same block use the previous call's output as the anchor.

```solidity
// PushOracle.sol:80-94
function setPrice(uint256 price1e18) external onlyOperator {
    if (price1e18 < _minPrice || price1e18 > _maxPrice) revert PriceOutOfBounds();

    uint256 prev = _price1e18;
    if (_updatedAt != 0) {
        // Reject out-of-band jumps vs the last pushed price (prev >= minPrice >= 1).
        uint256 maxDelta = Math.mulDiv(prev, _maxDeviationBps, BPS);
        uint256 lower = prev > maxDelta ? prev - maxDelta : 0;
        if (price1e18 > prev + maxDelta || price1e18 < lower) revert PriceDeviationTooLarge();
    }

    _price1e18 = price1e18;
    _updatedAt = block.timestamp;
    emit PriceUpdated(price1e18, block.timestamp);
}
```

## Impact
With operator-key compromise (the threat model the deviation guard is designed against), the attacker can:
1. Drop a collateral oracle's price to ~zero in a single tx → `RiskModule._computeHf` returns 0 for any user with that collateral → `isLiquidatable` returns true → attacker (as liquidator) calls `LiquidationEngine.liquidate`, paying near-zero in repay token and seizing all of the victim's collateral plus bonus.
2. Inflate a debt oracle's price → `debtUsd` becomes huge → otherwise-healthy borrowers become liquidatable.
3. Both attacks can run inside the same transaction as the price walk, so monitoring cannot react in time.

Downstream amplifier: `LiquidationEngine._usdToBaseUnits` (lines 197-202) computes `collateralSeized = usd * 1e18 / probeUsd`. When `probeUsd` is crushed, `collateralSeized` blows up. The cap at `availColl` (lines 152-165) is the only ceiling, and that ceiling equals "entire victim balance" — exactly what the attacker wants.

Magnitude: unbounded relative to the asset's TVL. `PushOracle` is the active oracle for all RWA / synthetic assets in scope per `PushOracle.sol:10-12` (IDRX, XSGD, XAUT, SLVon, NVDAon, AAPLon, TLTon).

This is the worst-case interpretation of "operator is trusted" because the entire `_maxDeviationBps` defense exists *specifically* to bound the damage from operator key compromise. The guard fails its stated objective.

## Step-by-Step Exploitation
Operator compromise → from a single attacker EOA / contract:
```
PushOracle(collateralFeed).setPrice(prev_price * 0.5);  // step 1
PushOracle(collateralFeed).setPrice(prev_price * 0.25); // step 2
...
PushOracle(collateralFeed).setPrice(prev_price * 0.01); // step ~7
LiquidationEngine.liquidate(victim, loanToken, maturity, collateral, type(uint256).max, 0);
```
Net result inside one transaction: collateral oracle says victim's collateral is worth 1% of reality; HF=0; attacker liquidates the entire collateral balance for ~1% of its real value plus the liquidation bonus.

## Proof of Concept
Not built (would require constructing a compromised-operator harness). The static-analysis confirmation is sufficient: the state writes at lines 91-92 unconditionally overwrite `_price1e18` and `_updatedAt`, so the next call's deviation check uses the manipulated anchor.

## Recommended Fix
Two independent and complementary fixes:

**Fix 1 — per-block rate limit (primary defense):**

```solidity
uint256 private constant MIN_PUSH_INTERVAL = 60; // seconds (or 1 block)

function setPrice(uint256 price1e18) external onlyOperator {
    ...
    if (_updatedAt != 0 && block.timestamp < _updatedAt + MIN_PUSH_INTERVAL) revert PushTooSoon();
    ...
}
```

Tuning `MIN_PUSH_INTERVAL` to the oracle's natural update cadence (e.g., 60s) limits per-block damage to a single 50%-step.

**Fix 2 — rolling time-window deviation accumulator:**

Track the price `_price1e18` and `_updatedAt` from N blocks ago, and enforce deviation against the *older* anchor in addition to the just-overwritten one. This prevents staircase walks even across blocks.

Fix 1 alone closes the same-tx variant. Fix 2 adds depth against gradual-walk operator misbehavior.

**Defensive companion fix on consumer side:** in `OracleRouter.tryGetUsdValue`, add sanity bounds per asset (`_priceBounds[asset]` mapping). Reject any feed return that falls outside `[minPrice, maxPrice]` configured at the router level. This protects the downstream RiskModule / LiquidationEngine even if a feed is misconfigured or compromised below the router.

## References
- `PushOracle.sol:21-24` NatSpec explicitly motivates SC-2 hardening for operator compromise — fail of stated objective.
- Cross-references in `LiquidationEngine.sol:146-150, 197-202` and `RiskModule.sol:188-228` show how downstream consumption magnifies the impact.

## Calibration

| field | value |
|-------|-------|
| `severity_post_gate` | High |
| `confidence_0_100` | 95 |
| `single_strongest_reject` | "Operator is trusted." — countered: the deviation guard is the explicit defense-in-depth against operator compromise; bypass nullifies the defense. |
| `smallest_falsifier` | Foundry single-tx test calling `setPrice(prev/2)` twice — confirm second call passes (50% of new anchor). |
| `gate_failures` | none |
| `poc_status` | NOT_BUILT (one-shot harness, easy to add pre-mainnet) |
