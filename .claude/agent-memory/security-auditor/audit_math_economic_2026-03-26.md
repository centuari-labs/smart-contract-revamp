---
name: Mathematical & Economic Invariant Audit 2026-03-26
description: Deep-dive audit of all mathematical operations, economic invariants, and precision safety across ~30 Centuari contracts. 1 CRITICAL (PCBTVault withdrawal queue drain), 4 MEDIUM, 2 LOW, 1 INFO.
type: project
---

## Mathematical & Economic Invariant Audit — 2026-03-26

**Scope**: All ~30 contracts in src/core/, src/adapters/, src/core/centuari/, src/core/pcbt/

### Findings

**CRITICAL (1)**:
- C-01: PCBTVault `_processWithdrawalQueue()` — totalValue computed once but supply decremented per withdrawal. Later queue entries get more USDC per share. Exploitable drain vector.

**MEDIUM (4)**:
- M-01: CentuariEndpoint.sol:312 — Refinance anchor rate bypass via `anchorRateBPS = 0`. Rollover already fixed (line 269). Inconsistency.
- M-02: RiskModule.sol:129,138 — `borrowAmount` in raw decimals compared against 18-decimal debt tracking. Debt ceiling and HF checks ineffective for non-18-dec tokens.
- M-03: All three adapters (Aave/Compound/Morpho) — `recall()` divides by `_totalShares[asset]` with no zero-check. `getDeployedValue()` has the guard but `recall()` does not.
- M-04: RiskModule.sol:168,179 — `reduceDebtAgainstAsset` and `reduceUserDebt` direct subtraction can underflow and revert liquidation due to debt split rounding.

**LOW (2)**:
- L-01: YieldRouter.sol:135-136 — recall tracking underflow if adapter returns more than tracked.
- L-02: FeeController.sol:186 — protocolRevenue underflow latent risk (mitigated by initialization validation).

**INFO (1)**:
- I-01: CentuariEndpoint.sol:230-252 — debt split rounding across collateral assets. Cosmetic, functional impact captured in M-04.

### Verified Correct
- CBT mint validation, interest formula, liquidation math, oracle integration, fee validation, adapter deploy bootstrap, insurance reserve ratio, grace period enforcement, L2 sequencer check.

**Why:** Pre-professional-audit deep-dive on all mathematical and economic invariants.
**How to apply:** C-01 must block any PCBTVault deployment. M-01 through M-04 should be fixed before mainnet. Check future changes to these files against these findings.
