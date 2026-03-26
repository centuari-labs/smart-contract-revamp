---
name: reconfirmation_audit_2_2026-03-25
description: Second reconfirmation audit verifying 13 findings (5C/5H/3M) against current code - ALL confirmed present
type: project
---

Second reconfirmation audit on 2026-03-25. Verified 13 specific findings from prior 5-agent audit against the actual source code.

## Result: 13/13 CONFIRMED PRESENT

### CRITICAL (5/5 confirmed)
- C-1: lockForOrder/debit mismatch — `_processMatches` calls `debit()` on `available` but `lockForOrder` moves funds to `locked`. No `consumeLocked` exists.
- C-2: `_processReturns` credits BalanceLedger with zero on-chain verification (no burn, no transfer, no position check). HSM trust only.
- C-3: Refinance anchor bypass — line 304 uses `if (r.anchorRateBPS > 0)` (conditional). Rollovers fixed with `require > 0`, refinances NOT fixed.
- C-4: 50% debt cap decimal mismatch — `debtToCover` (6-dec) compared against `maxCoverage` (18-dec). Cap never triggers for USDC.
- C-5: LiquidationEngine `(pricePerUnit18 * collPos.amount) / 1e18` — wrong for non-18-dec tokens. Cross-decimal liquidations produce wrong seizure amounts.

### HIGH (5/5 confirmed)
- H-1: 8+ instant admin setters across BalanceLedger, LiquidationEngine, YieldRouter, RiskModule. No timelocks.
- H-2: `_processGraceStarts` stores raw `gracePeriodEnds` with no MAX_GRACE_PERIOD validation. Permanent unliquidatable positions possible.
- H-3: `reduceUserDebt` uses raw `-=` with no underflow protection. Underflow permanently blocks liquidation.
- H-4: Refinance only adds delta to debt tracking, never removes old debt. `_userDebtUSD` inflates across cycles.
- H-5: `_getWeightedCollateralUSD` reads oracle but never checks staleness. HF computation uses potentially stale prices.

### MEDIUM (3/3 confirmed)
- M-1: No MAX_BATCH_SIZE enforcement in `submitSettlementBatch`.
- M-6: `depositToReserve` missing `nonReentrant`, external call before state update.
- M-7: `_latestRoundData` never validates `answeredInRound >= roundId`.

**Why:** These are all real, unfixed vulnerabilities in the current codebase as of 2026-03-25.
**How to apply:** All findings must be fixed before mainnet. C-4 and C-5 are the most immediately exploitable in production.
