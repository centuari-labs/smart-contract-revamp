---
name: CentuariEndpoint Deep Security Audit (2026-03-26)
description: Comprehensive 10-section audit of CentuariEndpoint.sol and all interacting core contracts. 0 CRITICAL, 0 HIGH, 3 MEDIUM, 4 LOW, 5 INFO. VERDICT: APPROVE (conditional on M-02).
type: project
---

## Audit: CentuariEndpoint.sol Deep Review — 2026-03-26

**Contracts reviewed**: CentuariEndpoint.sol, CentuariEndpointStorage.sol, BalanceLedger.sol, BalanceLedgerStorage.sol, RiskModule.sol, RiskModuleStorage.sol, LiquidationEngine.sol, LiquidationEngineStorage.sol, CollateralRegistry.sol, YieldRouter.sol, CentuariRouter.sol, AssetBehaviorRegistry.sol, CentuariBondERC20.sol, CentuariBondERC20Factory.sol, FeeController.sol, ICentuariEndpoint.sol

**All 25 security invariants: PASS**

### Findings

**MEDIUM (3):**
- M-01: RiskModule.getWeightedCollateralExcluding (line 68-85) uses stale `usdValueCached` while primary `getHealthFactor` uses live oracle prices. Inconsistency could allow collateral toggle manipulation.
- M-02: Refinance anchor rate check is CONDITIONAL (`if (r.anchorRateBPS > 0)` at line 312) while rollover check is UNCONDITIONAL (line 269). Engine can bypass anchor bounds for refinances by submitting anchorRateBPS=0. **Fix before mainnet.**
- M-03: `_processGraceStarts` (line 406-413) stores grace periods without enforcing MAX_GRACE_PERIOD_HOURS on-chain. Engine could submit arbitrarily long grace periods.

**LOW (4):**
- L-01: LiquidationEngine.setSpokeVaultRWA (line 339) has no timelock — instant admin setter.
- L-02: RiskModule.setSequencerUptimeFeed (line 386) has no timelock — instant admin setter.
- L-03: RiskModule.reduceDebtAgainstAsset (line 168) can underflow if debtUSD > _totalDebtAgainstAsset.
- L-04: Refinance debt delta (lines 347-350) only recorded when newPrincipal > oldDebt; debt reduction on refinance not tracked.

**INFO (5):**
- I-01: CentuariEndpoint uses low-level `.call()` for CBT mint/burn — typed interface calls preferred.
- I-02: BalanceLedger.withdraw() does not check HF — relies on available balance being separate from collateral.
- I-03: Settlement batch processing order is correct (liquidations first, grace starts last).
- I-04: All storage contracts have proper `__gap` arrays.
- I-05: CEI pattern followed consistently across all critical paths.

### Recurring Patterns Confirmed
- **Instant admin setters** (L-01, L-02): 11th+ time flagged across audits. setSpokeVaultRWA and setSequencerUptimeFeed join the pattern.
- **Stale cached oracle values** (M-01): getWeightedCollateralExcluding uses cached values while getHealthFactor uses live. Same pattern as prior audits.
- **Incomplete fix propagation** (M-02): Rollover anchor check is unconditional but refinance check is conditional — likely an oversight during implementation.

### VERDICT: APPROVE (conditional on M-02 anchor bypass fix before mainnet)
