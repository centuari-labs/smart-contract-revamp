# Centuari Hub-Core Security Audit Report

audit_date: 2026-06-05
source_commit: 8a9451194e27df4abaced439d1c49e119a9b2456
scope_sha256: 830db58d05b359747974cccdb6387fe2103b432871976ed19a351722dc93670f
auditor: Claude Opus 4.7 (web3-pentest skill, 6 parallel vuln-hunter agents + orchestrator)
target: src/core/{balance-ledger, centuari, collateral, liquidation, oracle, risk, settlement}/, src/libraries/, src/utils/
explicit out-of-scope: src/core/cross-chain/ (per user instruction)

## Executive Summary

The Centuari hub-side core (~3,300 SLoC) was audited end-to-end against the cross-chain-excluded scope. The architecture is clean: BalanceLedger as a writer-gated dumb-accounting substrate, policy concentrated in CollateralManager / RiskModule / LiquidationEngine, an interface-segregated oracle stack, an upgradeable-proxy pattern with disciplined storage layouts, and ERC7201-namespaced reentrancy guards.

The audit produced **one CRITICAL finding** with a passing Foundry PoC: `Centuari.withdrawLendPosition` does not validate that the `marketId` parameter matches `(loanToken, maturity)`. Any lender can drain Centuari's bond-token reserve for any matured market's loan token by passing mismatched parameters — destroying that market's lenders' redemption claims.

Two HIGH findings on the oracle layer affect mainnet readiness: a missing `minAnswer`/`maxAnswer` circuit-breaker check on `ChainlinkPriceFeed` (the canonical Venus/LUNA-class footgun), and a `PushOracle` deviation guard that is defeated by same-tx multi-call. Both gate the mainnet rollout per the project's own deployment doctrine.

Five MEDIUM findings cluster around defensive-check omissions and configuration hygiene. Three LOWs and seven INFOs round out the full ledger. All in-scope contracts compile cleanly; Slither's flags are either confirmed safe or are the same findings we surface manually with more context.

## Findings Summary

| # | Severity | Title | Contract | PoC Status |
|---|----------|-------|----------|------------|
| 1 | **CRITICAL** | Cross-market drain via mismatched `(marketId, loanToken, maturity)` in `withdrawLendPosition` | `Centuari.sol` | **PASSING** |
| 2 | HIGH | `ChainlinkPriceFeed` missing min/maxAnswer circuit-breaker check | `ChainlinkPriceFeed.sol` | NOT_BUILT |
| 3 | HIGH | `PushOracle` deviation guard defeated by same-tx multi-call | `PushOracle.sol` | NOT_BUILT |
| 4 | MEDIUM | `PushOracle` deploys with permissive defaults; deploy scripts never tighten | `PushOracle.sol` + `script/` | NOT_BUILT (verified by grep) |
| 5 | MEDIUM | `PushOracle.setBounds` does not re-validate stored price | `PushOracle.sol` | NOT_BUILT |
| 6 | MEDIUM | `Centuari.repay` / `liquidationRepay` accept arbitrary `loanToken` | `Centuari.sol` | NOT_BUILT (operator-trusted) |
| 7 | MEDIUM | Settlement batch DoS via fresh-address flag saturation | `CollateralManager.sol` + `Settlement.sol` | NOT_BUILT |
| 8 | MEDIUM | LiquidationEngine multi-call defeats per-call close factor for underwater positions | `LiquidationEngine.sol` | NOT_BUILT |
| 9 | LOW | `PushOracle.setOperator` does not reset price anchor | `PushOracle.sol` | NOT_BUILT |
| 10 | LOW | `OracleRouter.setFeed` does not enforce `setMaxStaleness` atomically | `OracleRouter.sol` | NOT_BUILT |
| 11 | LOW | `PushOracle` first-push exemption + `[1, MAX]` defaults | `PushOracle.sol` | NOT_BUILT |
| 12 | INFO | Day-count interest deducts one day from every loan | `Centuari.sol` | N/A |
| 13 | INFO | HF formula far more conservative than industry standard | `RiskModule.sol` | N/A |
| 14 | INFO | Pre-upgrade > 64-market borrowers not fully reconcilable | `Centuari.sol` | N/A |
| 15 | INFO | BalanceLedger storage gap comment under-counts used slots | `BalanceLedgerStorage.sol` | N/A |
| 16 | INFO | Slither-flagged reentrancy false-positives in `settleMatch` / `withdrawLendPosition` | `Centuari.sol` | N/A |
| 17 | INFO | `_marketLoanToken` non-canonical persistence on set-once write | `Centuari.sol` | N/A |

## Detailed Findings

Each finding has its own write-up in `findings/`:

- [CRITICAL — Cross-market drain in `withdrawLendPosition`](findings/CRITICAL_withdraw_cross_market_drain.md)
- [HIGH — ChainlinkPriceFeed missing min/maxAnswer check](findings/HIGH_chainlink_missing_min_max_answer.md)
- [HIGH — PushOracle deviation guard multi-call](findings/HIGH_pushoracle_deviation_guard_multicall.md)
- [MEDIUM — PushOracle unset bounds at deploy](findings/MEDIUM_pushoracle_unset_bounds_at_deploy.md)
- [MEDIUM — setBounds doesn't re-validate stored price](findings/MEDIUM_setbounds_doesnt_revalidate_stored_price.md)
- [MEDIUM — repay/liquidationRepay loanToken unchecked](findings/MEDIUM_repay_loantoken_unchecked.md)
- [MEDIUM — Settlement batch DoS via flag saturation](findings/MEDIUM_settlement_batch_dos_flag_saturation.md)
- [MEDIUM — Liquidation multi-call close-factor bypass](findings/MEDIUM_liquidation_multicall_closefactor_bypass.md)
- [LOW — PushOracle setOperator no anchor reset](findings/LOW_pushoracle_setoperator_no_anchor_reset.md)
- [LOW — OracleRouter setFeed no atomic staleness](findings/LOW_oraclerouter_setfeed_no_atomic_staleness.md)
- [LOW — PushOracle first-push freedom](findings/LOW_pushoracle_first_push_freedom.md)
- [INFO — Day-count off-by-one](findings/INFO_day_count_off_by_one.md)
- [INFO — HF formula conservatism](findings/INFO_hf_formula_conservatism.md)
- [INFO — Pre-upgrade > 64-market borrowers](findings/INFO_pre_upgrade_max_debt_markets.md)
- [INFO — BalanceLedger gap comment](findings/INFO_balanceledger_gap_comment.md)
- [INFO — Slither reentrancy false-positives](findings/INFO_slither_reentrancy_false_positives.md)
- [INFO — `_marketLoanToken` non-canonical persistence](findings/INFO_marketloantoken_non_canonical.md)

See also `CANDIDATES.md` for the full ledger including rejected hypotheses with proof.

## Methodology

**Static + dynamic + adversarial:**
- Manual inspection of every in-scope `.sol` file at the audit commit.
- Slither `human-summary` + 20+ targeted detectors. See `slither-summary.txt` and `slither-high-impact.txt`.
- Six parallel `vuln-hunter` sub-agents over disjoint subsystems (BalanceLedger, Centuari core, Bond + Factory, Settlement+CollateralManager, LiquidationEngine, RiskModule, Oracle stack). Each agent received the architecture map, invariant claims, Slither output, attack-vector domain docs, and an explicit framing of "operator/owner are trusted; findings against trusted-role exclusion only when permissionless reachability is real."
- Orchestrator independently reviewed the most attack-surface-rich functions (`withdrawLendPosition`, `settleMatch`, `liquidate`) and verified or refuted agent claims with code-line citation.
- Foundry PoC for the CRITICAL finding (passing). Other findings have static-analysis confirmation; pre-mainnet PoCs recommended for HIGH-2 / HIGH-3.

**Tooling versions:**
- `forge 1.x`, `solc 0.8.30` (via_ir + optimizer enabled per `foundry.toml`).
- `slither 0.11.5`.
- Network: not on a fork (pure source + local Anvil-style harness for the PoC).

## Anti-hallucination check

- Every `file:line` citation in this report and the per-finding write-ups was verified against the source at the audit commit via direct `awk` extraction (see Bash transcripts).
- Every contract, function, error, and modifier referenced has been grep-confirmed to exist.
- No external addresses are claimed (audit is source-only; no on-chain reads).
- All claims that depend on math have been re-derived from first principles where the agent's derivation looked suspect (RiskModule's HF formula claim was rejected after independent derivation; see INFO `INFO_hf_formula_conservatism.md`).

**Status: all cites verified.**

## Recommended next steps for the team

1. **Fix the CRITICAL immediately.** A single-line `marketId == _getMarketId(loanToken, maturity)` assert at `Centuari.sol:329-357` closes the door. Companion fix for `repay` and `liquidationRepay` (MEDIUM #6) at the same time — same one-line check, defense in depth.
2. **Before any mainnet rollout, fix the two HIGH oracle findings:**
   - Wire `ChainlinkPriceFeed` to read the underlying `Aggregator`'s `minAnswer`/`maxAnswer` and fail-closed at the rails (HIGH #2).
   - Add a per-block rate limit on `PushOracle.setPrice` (HIGH #3). Either a `MIN_PUSH_INTERVAL` of ~60 seconds, or a same-block guard via `_updatedAt == block.timestamp ⇒ revert`.
3. **Tighten deploy scripts** to atomically call `setBounds` and `setMaxDeviationBps` per-asset on `PushOracle` deploy, and add a deploy-time invariant assertion that no feed is exposed via `OracleRouter.setFeed` until both are set with non-default values (MEDIUM #4, LOW #11).
4. **Audit-line check** for any pre-upgrade borrower with > 64 debt markets before mainnet (`INFO_pre_upgrade_max_debt_markets.md`).
5. **Re-verify the cross-chain scope separately** — it is out-of-scope for this audit but shares the BalanceLedger writer trust boundary.

## Out of Scope

Per user instruction ("tolong audit contract ini semua scope yang ada kecuali crosschain"):

- All of `src/core/cross-chain/`: HubDepositor, HubIntentSettler, SettlementLedger, WithdrawalRegistry, and all spoke contracts.
- All of `src/interfaces/cross-chain/`.
- Mock contracts under `src/mocks/`.
- The off-chain matching engine, indexer, and backend.

Cross-chain code shares the BalanceLedger writer trust boundary but no findings here would be affected by a separate cross-chain review.

## Artefacts

```
docs/audit-2026-06-05/
├── findings/                                # per-finding write-ups (17 files)
├── fuzzing/                                 # (no harnesses built; Foundry PoC under test/exploits/)
├── ARCHITECTURE.md                          # component map + key flows
├── AUDIT_REPORT.md                          # this file
├── CANDIDATES.md                            # full candidate ledger + rejections
├── INVARIANTS.md                            # invariants and adversarial framings
├── PHASE4_PLAN.md                           # subsystem split for vuln-hunter agents
├── SAFETY_PREFLIGHT.md                      # scope, allowed/forbidden actions
├── SCOPE.md                                 # in-scope contract list
├── slither-high-impact.txt                  # static analysis output
└── slither-summary.txt                      # static analysis human-summary

test/exploits/centuari-2026-06-05/
└── WithdrawCrossMarketDrain.t.sol           # passing PoC for the CRITICAL finding
```

Run the PoC:
```bash
forge test --match-path "test/exploits/centuari-2026-06-05/WithdrawCrossMarketDrain.t.sol" -vv
```
