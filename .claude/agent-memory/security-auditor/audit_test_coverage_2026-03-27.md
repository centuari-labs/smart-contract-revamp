---
name: Test Coverage Audit 2026-03-27
description: Comprehensive test coverage audit of ~45 test files. 13 CRITICAL, 12 HIGH, 15 MEDIUM, 8 LOW missing test gaps identified.
type: project
---

## Test Coverage Audit — 2026-03-27

Audited ~45 test files across test/core/, test/integration/, test/spoke/, test/adapters/, test/centuari/.

### Critical Findings (13)
- C-01: DualOracle.t.sol — ALL 5 tests are stubs. Zero dual-oracle coverage.
- C-02: SecurityInvariants.t.sol — 6 stubs (#3,5,8,11,13,14) + invariants #17-25 have no tests.
- C-03: RiskModule — usdValueCached always 0 in tests. Weighted HF never tested with real values.
- C-04: No negative/zero oracle price test anywhere. _latestRoundData() doesn't check answer > 0.
- C-05: PCBTVault — No withdrawal queue drain test (CRITICAL from prior audit).
- C-06: FuzzTests — Pure math only. No contract-level fuzzing of any entry point.
- C-07: LiquidationEngine — No decimal mismatch test (6-dec vs 18-dec).
- C-08: CentuariEndpoint — Zero test coverage for rollover/refinance/liquidation settlements.
- C-09: BalanceLedger — No real ERC20 deposit()/withdraw() test.
- C-10: YieldRouter — Uses mock BalanceLedger, never tested with real one.
- C-11: Invariant #21 (withdraw-while-paused) untested.
- C-12: Invariant #23 (interest-before-HF) untested.
- C-13: Fee distribution path in CentuariEndpoint untested.

### High Findings (12)
- FlowC rollover: no new CBT mint verification
- FlowD refinance: anchorRateBPS=0 bypasses bounds check
- LiquidationEngine: frozen collateral + liquidator whitelist mocked away
- YieldRouter: 60% per-protocol cap untested
- ERC-4626: no working deposit/withdraw flow, no inflation attack test
- WithdrawalRegistry: no withdrawal-while-paused
- Treasury: reentrancy test stubs empty
- FlowI: no rollover/refinance in mixed batch
- Adapters: no paused adapter test
- FlowF: no 6-dec vs 18-dec decimal test
- No cross-function reentrancy test

### Recurring Patterns
1. Mocks bypass real security logic (RiskModule usdValueCached=0, liquidator whitelist mock, mock BalanceLedger in YieldRouter)
2. Integration tests cover happy path only, missing edge cases
3. Stub tests left from early development never implemented
4. Pure math fuzzing provides false confidence — no contract-level fuzzing
5. Oracle edge cases (stale, zero, negative, divergent) systematically undertested
