# Security Auditor Memory Index

## Audit Reports
- [audit_2026-03-23.md](audit_2026-03-23.md) — Full pre-audit security review of all src/core/ contracts. 5 CRITICAL, 9 HIGH, 12 MEDIUM findings. VERDICT: REQUEST CHANGES.
- [audit_2026-03-24.md](audit_2026-03-24.md) — Post-remediation audit of all src/core/, src/spoke/, src/core/centuari/, src/core/pcbt/ contracts. 15/16 prior fixes verified. 3 CRITICAL, 4 HIGH, 8 MEDIUM findings. VERDICT: REQUEST CHANGES.
- [audit_2026-03-25.md](audit_2026-03-25.md) — Definitive final audit of 12 hub core contracts. 2 CRITICAL (stale HF gating + no token transfer in liquidation), 3 HIGH (missing timelocks, debt double-count, instant auth setter). VERDICT: NEEDS CHANGES.

- [audit_blackhat_2026-03-25.md](audit_blackhat_2026-03-25.md) — Black hat adversarial audit: 18 attack attempts. 3 CRITICAL (LiquidationEngine decimal mismatch, CBT redemption pool drain, unbacked credits), 5 HIGH (instant admin setters, anchor bypass, grace period bypass), 4 MEDIUM.

## Formal Invariant Verification
- [invariant_verification_2026-03-25.md](invariant_verification_2026-03-25.md) — Mathematical invariant verification of 8 invariants across all core contracts. I1/I2 CRITICAL violations (conservation of value, CBT backing). I4 MEDIUM (debt tracking). I7/I8 HIGH (access control bypass via non-timelocked admin setters).

## Upgrade Safety
- [audit_upgrade_safety_2026-03-25.md](audit_upgrade_safety_2026-03-25.md) — Upgrade safety and storage layout audit of all 20 contracts. 2 CRITICAL (state vars in impl after __gap), 1 MEDIUM (missing timelock), 2 LOW, 1 INFO. VERDICT: REQUEST CHANGES.

## Reconfirmation Audits
- [reconfirmation_audit_2026-03-25.md](reconfirmation_audit_2026-03-25.md) — Reconfirmed 4 invariant violations (I1 processReturns, I2 redeemCBT, I4 refinance debt, I7/I8 instant setters) all still present in current code.

## Fresh Eyes / Targeted Audits
- [audit_fresh_eyes_2026-03-25.md](audit_fresh_eyes_2026-03-25.md) — Targeted audit of FeeController, CentuariRouter, CentuariRateOracle, WithdrawalRegistry, and cross-contract interactions. 2 CRITICAL (unbacked fee credits, withdrawal fund loss), 3 HIGH, 5 MEDIUM. VERDICT: REQUEST CHANGES.

## Reentrancy / CEI / Access Control
- [audit_reentrancy_cei_access_2026-03-25.md](audit_reentrancy_cei_access_2026-03-25.md) — Full reentrancy, CEI, and access control audit of all 40 contracts. 10 HIGH (instant admin setters across 9 contracts), 8 MEDIUM (missing nonReentrant, instant non-critical setters). CEI generally followed. nonReentrant coverage good on critical paths.

## Cross-Function / System-Level Audits
- [audit_cross_function_2026-03-25.md](audit_cross_function_2026-03-25.md) — Cross-function invariants, DoS vectors, system-level attacks. 3 CRITICAL (unbacked returns, lockForOrder/debit mismatch, refinance anchor bypass), 4 HIGH (debt underflow DoS, unbounded arrays, grace period manipulation), 5 MEDIUM.

## Arithmetic / Oracle / Economic Deep-Dive
- [audit_arithmetic_oracle_2026-03-25.md](audit_arithmetic_oracle_2026-03-25.md) — Deep-dive on integer arithmetic, oracle security, economic attacks. 2 CRITICAL (LiquidationEngine decimal mismatches in seizure and cap), 4 HIGH (stale HF oracle, refinance anchor bypass, unbacked returns, instant admin setters), 5 MEDIUM. Recurring patterns #1, #4, #6, #7 confirmed again.

## Final Pre-Professional-Audit Review
- [audit_final_preaudit_2026-03-26.md](audit_final_preaudit_2026-03-26.md) — FINAL review before third-party audit. 0 CRITICAL, 0 HIGH, 3 MEDIUM, 4 LOW, 5 INFO. All 25 invariants PASS. All 8 past-audit regressions PASS. VERDICT: READY (conditional on M-01 decimal fix in LiquidationEngine.liquidate and M-02 refinance anchor bypass).

## Absolute Final Audit
- [audit_final_absolute_2026-03-26.md](audit_final_absolute_2026-03-26.md) — ABSOLUTE FINAL audit of all 15 core contracts + storage. 0 CRITICAL, 0 HIGH, 2 MEDIUM (YieldRouter storage after __gap, setSpokeVaultRWA no timelock), 3 LOW. All 25 invariants PASS. All 10 specific checks PASS. VERDICT: CLEAN FOR AUDIT.

## Recurring Patterns
- [recurring_patterns.md](recurring_patterns.md) — Cross-audit vulnerability patterns: incomplete fix propagation, accounting without token transfer, queue without escrow, missing timelocks, stale cached oracle values.
