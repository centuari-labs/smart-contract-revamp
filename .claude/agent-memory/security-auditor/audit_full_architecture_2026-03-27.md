---
name: Full Architecture Audit — 10-Agent Results (2026-03-27)
description: FINAL comprehensive protocol-wide security audit. 10 parallel Opus agents audited every Centuari contract. All 10 completed. 4 CRITICAL, 7 HIGH, 13+ MEDIUM found. VERDICT — REQUEST CHANGES.
type: project
---

# Full Architecture Audit — Centuari Smart Contract Revamp
**Date**: 2026-03-27
**Branch**: fix/final-audit-cleanup
**Status**: COMPLETE (10/10 agents finished)
**Overall Verdict**: REQUEST CHANGES — 4 CRITICAL findings must be fixed before mainnet

## Agent Completion Status

| # | Domain | Verdict | CRIT | HIGH | MED | LOW |
|---|--------|---------|------|------|-----|-----|
| 1 | CentuariEndpoint Settlement | APPROVE (conditional) | 0 | 0 | 1 | 0 |
| 2 | BalanceLedger Deposit/Withdraw | REQUEST CHANGES | 0 | 2 | 5 | 4 |
| 3 | RiskModule + LiquidationEngine | REQUEST CHANGES | 1 | 1 | 3 | 3 |
| 4 | YieldRouter + Adapters | REQUEST CHANGES | 2 | 2 | 4 | 2 |
| 5 | CBT + Bond Factory | APPROVE (conditional) | 0 | 1 | 0 | 0 |
| 6 | AssetBehaviorRegistry + CollateralRegistry | REQUEST CHANGES | 0 | 0 | 4 | 3 |
| 7 | Original Settlement/Centuari/Treasury | REQUEST CHANGES | 1 | 0 | 0 | 0 |
| 8 | Access Control + Upgradeability | REQUEST CHANGES | 0 | 4 | 5 | 3 |
| 9 | Economic/Math Invariants | REQUEST CHANGES | 1 | 0 | 4 | 2 |
| 10 | Test Coverage + Gaps | N/A (test audit) | 13 gaps | 12 gaps | 15 gaps | 8 gaps |

---

## CRITICAL FINDINGS (4 unique, de-duplicated)

### C-01: RiskModule `validateBorrow()` decimal mismatch — undercollateralized borrowing
**Source**: Agent 3
**File**: `src/core/RiskModule.sol:129, 138`
**Description**: `validateBorrow()` adds raw 6-decimal `borrowAmount` (e.g., USDC) to 18-decimal debt values. This makes the debt ceiling check and HF check effectively non-binding for non-18-decimal tokens. A borrower can borrow 10x their collateral value.
**Impact**: Complete protocol insolvency. Any borrower can bypass collateral requirements for USDC/USDT.
**Fix**: Normalize `borrowAmount` to 18 decimals before both comparisons.

### C-02: YieldRouter `rebalance()` has 4 fatal bugs — fund loss
**Source**: Agent 4
**File**: `src/core/YieldRouter.sol:200-276`
**Description**: (A) Passes token amount as `shares` param to adapter.recall(), (B) No BalanceLedger sync after rebalance, (C) No ERC20 approval before deploy, (D) No share tracking update.
**Impact**: Fund loss, permanent accounting desync between YieldRouter and BalanceLedger.
**Fix**: Complete rewrite of `rebalance()`.

### C-03: PCBTVault `_processWithdrawalQueue()` fund loss vulnerability
**Source**: Agent 9
**File**: `src/core/pcbt/PCBTVault.sol:199-230`
**Impact**: Users may lose funds during maturity settlement withdrawal processing.

### C-04: Treasury operator can drain any user's funds (original architecture)
**Source**: Agent 7
**File**: `src/core/Treasury.sol:106-125`
**Description**: Operator/admin can drain funds via `setCentuariContract()` → fake settle → withdraw. No timelock on any admin setter.
**Impact**: Total fund loss if operator key compromised. Applies to the legacy architecture only.

---

## HIGH FINDINGS (7 unique, de-duplicated)

### H-01: LiquidationEngine decimal mismatch blocks all USDC liquidations
**Source**: Agent 3
**File**: `src/core/LiquidationEngine.sol:122`
**Description**: `freshCollateralUsdValue` divides by `1e18` instead of `10**tokenDecimals`. For 6-decimal tokens, `_computeSeizure()` always returns a value > `collPos.amount`, making liquidation revert. Combined with C-01: borrow unlimited + can't be liquidated.
**Fix**: Use `(pricePerUnit18 * collPos.amount) / (10 ** tokenDecimals)`.

### H-02: BalanceLedger `setAsCollateral()` uses stale cached prices
**Source**: Agent 2
**File**: `src/core/BalanceLedger.sol:202` + `src/core/RiskModule.sol:79`
**Fix**: `getWeightedCollateralExcluding()` must use live oracle path.

### H-03: BalanceLedger missing `collateralEligible` check
**Source**: Agents 2, 6
**File**: `src/core/BalanceLedger.sol:190, 196`
**Fix**: Add `collateralEligible` check from AssetBehaviorRegistry.

### H-04: CentuariEndpoint refinance anchor rate bypass (Invariant #15)
**Source**: Agents 1, 3, 5, 6, 9 (flagged 5+ times independently)
**File**: `src/core/CentuariEndpoint.sol:312`
**Fix**: Change `if (r.anchorRateBPS > 0)` to unconditional `require(r.anchorRateBPS > 0)`.

### H-05–H-08: Missing timelocks on admin setters
**Source**: Agents 7, 8
- **H-05**: PCBTVault `setWithdrawalCutoff/setNextMaturity/setCurrentCBT` (lines 312-325)
- **H-06**: RiskModule `setSequencerUptimeFeed` (line 386)
- **H-07**: LiquidationEngine `setSpokeVaultRWA` (line 339)
- **H-08**: SpokeVaultRWA `setLayerZeroEndpoint/setHubLiquidationEngine/setHubChainEid`
**Fix**: Add propose/apply/cancel 48h timelock pattern to all.

---

## MEDIUM FINDINGS (13+ unique)

| ID | Contract | Description |
|----|----------|-------------|
| M-01 | AssetBehaviorRegistry:127 | `updateAsset()` immediately overwrites LTV despite pendingLTVChanges — discrete governance bypassed |
| M-02 | BalanceLedger:239 | `reduceCollateral()` ignores sourceChainId |
| M-03 | BalanceLedger:168,238 | Unbounded `_collateral[user]` array — DoS vector against liquidation |
| M-04 | BalanceLedger:315 | `updateCollateralUsdValue()` silently returns if asset not found |
| M-05 | BalanceLedger:334 | Single pending writer proposal overwrite |
| M-06 | BalanceLedgerStorage:51 | Storage gap arithmetic may be incorrect |
| M-07 | RiskModule:129,138 | `validateBorrow` doesn't normalize borrowAmount to 18 decimals |
| M-08 | RiskModule:168,179 | `reduceDebtAgainstAsset`/`reduceUserDebt` can underflow — DoS liquidations |
| M-09 | AaveV3Adapter:59 | recall division-before-subtraction accounting drift |
| M-10 | AssetBehaviorRegistry:286 | `_validateBehavior()` missing critical checks (priceFeed, maxStaleness) |
| M-11 | BalanceLedger+RiskModule | `collateralEligible` and `lendable` flags never enforced on-chain |
| M-12 | YieldRouter:200-276 | Additional rebalance medium findings (4 total) |
| M-13 | RiskModule:144-148 | `minBorrowAmount` check ordering wastes gas |

---

## CROSS-CUTTING PATTERNS (recurring across 5+ audits)

1. **Decimal normalization gaps**: 6-decimal USDC amounts compared to 18-decimal USD values without normalization (C-01, H-01, M-07)
2. **Stale cached oracle values**: `usdValueCached` used in security-critical paths while live oracle available (H-02, M-01 from prior audits)
3. **Refinance anchor rate bypass**: Conditional vs unconditional check at CentuariEndpoint.sol:312 — flagged 5+ times, STILL UNFIXED
4. **Missing timelocks on admin setters**: Across 8+ contracts, 10+ admin functions have no timelock
5. **Mocks bypass real security logic in tests**: RiskModule usdValueCached=0, mock BalanceLedger in YieldRouter, mock liquidator whitelist

---

## TEST COVERAGE CRITICAL GAPS (from Agent 10)

1. DualOracle tests ALL stubs (5/5) — #2 DeFi attack vector completely untested
2. SecurityInvariants: 6 stubs + invariants #17-25 missing entirely
3. RiskModule weighted HF never tested with real collateral values
4. No negative/zero oracle price test anywhere
5. PCBTVault withdrawal queue drain — zero test coverage
6. Fuzz tests are pure math only — no contract entry points fuzzed
7. CentuariEndpoint rollover/refinance/liquidation paths completely untested
8. No real ERC20 deposit/withdraw test in BalanceLedger

---

## FIX PRIORITY ORDER (for mainnet readiness)

### P0 — Must fix before any deployment
1. **C-01**: Normalize `borrowAmount` in `validateBorrow()` (RiskModule.sol:129,138)
2. **H-01**: Fix `freshCollateralUsdValue` decimal divisor (LiquidationEngine.sol:122)
3. **H-04**: Make refinance anchor rate check unconditional (CentuariEndpoint.sol:312)
4. **C-02**: Rewrite `rebalance()` in YieldRouter

### P1 — Must fix before mainnet
5. **H-02**: `getWeightedCollateralExcluding()` use live oracle
6. **H-03**: Add `collateralEligible` check in BalanceLedger
7. **M-01**: Fix `updateAsset()` LTV overwrite in AssetBehaviorRegistry
8. **M-08**: Add underflow protection to debt reduction functions
9. **H-05–H-08**: Add timelocks to all missing admin setters

### P2 — Should fix before mainnet
10. **M-02–M-06**: BalanceLedger medium fixes
11. **C-03**: PCBTVault withdrawal queue fix
12. **M-10**: `_validateBehavior()` missing checks
13. Test coverage: DualOracle, SecurityInvariants, contract-level fuzzing

---

## DETAILED REPORTS (per agent)

Individual audit reports saved in:
- `.claude/agent-memory/security-auditor/audit_riskmodule_liqengine_2026-03-27.md`
- `.claude/agent-memory/security-auditor/audit_abr_cr_2026-03-27.md`
- `.claude/agent-memory/security-auditor/audit_test_coverage_2026-03-27.md`
- `.claude/agent-memory/security-auditor/audit_access_control_2026-03-26.md`
- `.claude/agent-memory/security-auditor/audit_cbt_bond_2026-03-26.md`
- `.claude/agent-memory/security-auditor/audit_balanceledger_2026-03-26.md`
- `.claude/agent-memory/security-auditor/audit_endpoint_deep_2026-03-26.md`
- `.claude/agent-memory/security-auditor/audit_yieldrouter_2026-03-26.md`
- `.claude/agent-memory/security-auditor/audit_math_economic_2026-03-26.md`
