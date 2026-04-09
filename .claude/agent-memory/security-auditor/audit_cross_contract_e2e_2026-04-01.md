---
name: Cross-Contract E2E Security Audit (2026-04-01)
description: Mainnet-grade adversarial audit of cross-contract interactions, end-to-end flows, flash loan vectors, reentrancy, economic attacks, and all 25 security invariants across all src/core/ contracts.
type: project
---

## Summary
Comprehensive cross-contract security audit covering 15 core contracts, 14 integration tests, all 25 security invariants, and adversarial attack surface analysis. Code maturity is high after ~12 prior audit rounds. Most critical attack vectors addressed. Two MEDIUM and several LOW findings remain.

## Key Findings
- M-01: CBT redemption pool drain — `redeemCBT` transfers from BalanceLedger's ERC20 balance but this balance backs ALL user deposits, not just CBT. No segregation.
- M-02: `_processReturns` credits unbacked credits — no underlying token transfer, just BalanceLedger.credit().
- M-03: `processRefinances` only records debt INCREASE but never reduces old debt — refinance creates phantom cumulative debt.
- All 25 invariants PASS structurally (enforcement mechanisms present), though stub tests weaken confidence for #3, #5, #8, #11, #13, #14.
