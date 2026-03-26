---
name: reconfirmation_audit_2026-03-25
description: Reconfirmation of 4 invariant violations (I1 processReturns no CBT burn, I2 redeemCBT unfunded, I4 refinance debt decrease, I7/I8 16 instant setters) — all CONFIRMED still present in code
type: project
---

## Reconfirmation Audit — 2026-03-25

All 4 invariant violations from previous audits CONFIRMED still present:

1. **I1 CRITICAL** — `_processReturns()` (CentuariEndpoint.sol:360-370) credits lender balance without burning CBT or validating amount
2. **I2 CRITICAL** — `redeemCBT()` (CentuariEndpoint.sol:503-525) transfers full CBT face value (principal+interest) but interest portion is unfunded until borrower repays. `transferOut()` has no solvency check.
3. **I4 MEDIUM** — `_processRefinances()` (CentuariEndpoint.sol:313) only handles `newPrincipal > oldDebt`. No else branch for debt decrease via `reduceUserDebt()`.
4. **I7/I8 HIGH** — 16 instant onlyOwner setters without timelocks across BalanceLedger(2), RiskModule(2), LiquidationEngine(3), CollateralRegistry(4), YieldRouter(3), CentuariRateOracle(1). CentuariEndpoint was fixed.

**Why:** These represent the most critical outstanding issues blocking mainnet readiness.
**How to apply:** Any PR touching these contracts should verify these are addressed before approval.
