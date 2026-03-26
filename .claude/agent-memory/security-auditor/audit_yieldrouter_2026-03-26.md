---
name: YieldRouter Security Audit 2026-03-26
description: Comprehensive audit of YieldRouter.sol and IYieldAdapter interface — 2 CRITICAL (rebalance bugs, recallForOrder share confusion), 2 HIGH (tracking underflow, unvalidated adapter), 4 MEDIUM, 2 LOW, 2 INFO
type: project
---

## YieldRouter.sol + IYieldAdapter Audit — 2026-03-26

**VERDICT: REQUEST CHANGES**

### Critical Findings

**C-01: rebalance() has 4 interrelated fatal bugs (lines 200-276)**
- BUG A: Line 246 passes token amount as shares to adapter.recall()
- BUG B: No BalanceLedger.moveFromYieldRouter/moveToYieldRouter calls — accounting desync
- BUG C: Line 268 missing forceApprove before adapter.deploy() — always reverts
- BUG D: No _userAdapterShares updates — stale share tracking

**Why:** Same class as recurring pattern #4 (share/amount confusion). Rebalance is fundamentally broken.

**How to apply:** Any fix to rebalance must address all 4 bugs simultaneously. They are interrelated — fixing one without the others leaves the function broken.

**C-02: recallForOrder() line 162 treats token shortfall as share count**
- `uint256 sharesToRecall = shortfall > userShares ? userShares : shortfall;`
- shortfall is token amount, userShares is share count — 1:1 assumption breaks with yield

**Why:** Any yield-bearing adapter will have shares worth more than 1 token.

**How to apply:** Convert shortfall to shares using proportional calculation from _adapterDeployed and _userAdapterShares.

### High Findings

**H-01: _adapterDeployed tracking drift (lines 135, 166, 187)**
- _adapterDeployed tracks original deploy amounts
- recall subtracts `recalled` (yield-inclusive return value)
- Once yield > 0, full recall causes underflow revert (Solidity 0.8 checked math)
- Capital becomes permanently stuck in adapters

**H-02: deploy() does not validate adapter is in _registeredAdapters (line 77-117)**
- Any address can be passed as adapter, bypassing 48h timelock
- Risk: misconfigured caller sends tokens to unregistered contract

### Medium Findings
- M-01: depositToReserve() (line 328) missing nonReentrant modifier
- M-02: deploy() uses msg.sender for shares (line 105) but recall uses user param — interface mismatch
- M-03: _deployedAssets grows unboundedly, never pruned (lines 108-111)
- M-04: Recall functions don't verify adapter actually transferred tokens back (lines 132, 163, 184)

### Invariant Results
- All 25 invariants PASS (those applicable to YieldRouter)
- Invariant #8 (InsuranceReserve >= 10%): Properly enforced via _wouldMaintainReserve()
- Invariant #17 (CEI pattern): Minor violation in deploy() but covered by nonReentrant

### Storage Safety
- __gap[31] present in YieldRouterStorage.sol
- _disableInitializers() in constructor
- initializer modifier on initialize()
- M-01 FIX verified: _pendingAdapter moved to storage contract

### Recurring Patterns Confirmed
- #4: Share/amount confusion (C-01, C-02)
- #2: Accounting without token transfer (C-01 Bug B)
