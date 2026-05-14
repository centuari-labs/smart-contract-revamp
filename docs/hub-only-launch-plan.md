# Hub-Only Launch Plan

> **Status:** drafted 2026-05-14. **ACTIVE** — this is the working checklist for current development.
>
> For deferred cross-chain work (M5 spokes, M7 sweeper bot, M8 LZ patches, M10 Phase 2 chain selectors, solver fast-fill), see [`cross-chain-launch-plan.md`](./cross-chain-launch-plan.md).

---

## 1. Context

Centuari is launching **hub-only on Arbitrum** first, then adding cross-chain in a follow-on phase. Hub-only means:

- All deposits go through `HubDepositor.deposit(asset, amount)` on Arbitrum (single tx, ~15s).
- All withdrawals go through `WithdrawalRegistry.requestWithdrawal` → `HubDepositor.payoutDirect` on Arbitrum (no LayerZero).
- Lending, borrowing, settlement, collateral lifecycle all run on the hub contracts already deployed.
- No LayerZero, no spokes, no sweeper bot, no per-chain liquidity tracking, no cross-chain UI.

**Goal:** ship a usable lending/borrowing protocol on Arbitrum without the LayerZero dependency. The cross-chain feature is fully designed and partly built — it picks back up in the follow-on phase per [`cross-chain-launch-plan.md`](./cross-chain-launch-plan.md).

---

## 2. Already Hub-Ready (no action needed)

| Layer | Status | Notes |
|---|---|---|
| **Smart contracts** | ✅ DONE | BalanceLedger (M1, 2026-04-09), RiskModuleStub + CollateralManager (M1b, 2026-04-09), Centuari migrated off Treasury (M2, 2026-04-10), HubDepositor + deployment orchestration (M3, 2026-04-10), WithdrawalRegistry hub-native path (M4, 2026-04-12). 339+ tests passing. |
| **Collateral lifecycle (P1b-explicit)** | ✅ DONE 2026-04-17 | `Centuari.settleMatch` iterates `MatchData.collateralAssets[]` and flags only what borrower explicitly requested; `Centuari.repay` never touches flags; `CollateralManager.unflagFor` is the single unflag seam with 24h flag-lock + RiskModule gate. Reference: [`collateral-loophole-fix-plan.md`](./archive/collateral-loophole-fix-plan.md). |
| **Matching engine collateral plumbing** | ✅ DONE 2026-04-28 | `collateralAssets: string[]` on borrow schemas; `borrowerCollateralAssets` on match schema; preserved across partial fills; Redis stream round-trip. 505/505 jest tests. |
| **Settlement engine MatchData encoding** | ✅ DONE 2026-04-28 | Dedupes `borrowerCollateralAssets` per borrower, encodes into `MatchData.collateralAssets`. `pending_collateral_flags` queue cleared on settlement success via receipt `CollateralFlagSet` events. |
| **Backend collateral endpoints** | ✅ DONE | `POST /collateral/{flag,unflag}` with Privy JWT + 10/wallet/24h rate limit + 20-row queue cap. `applyOnChainEffect` C10 stamps inline. Reference: [`collateral-frontend-implementation.md`](./archive/collateral-frontend-implementation.md). |
| **Indexer-v3 hub processors** | ✅ DONE | BalanceLedger, Centuari, HubDepositor, WithdrawalRegistry, CollateralManager all wired against 5-param `CollateralFlagSet(writer, user, asset, used, flaggedAt)` event. Phase A `apply-on-chain-effect ^0.2.0` shared helper with `receipt` + `logIndex` overloads. |
| **Order lock lifecycle (Phase 1A + 1B)** | ✅ DONE 2026-05-10 | Settlement-engine writeback (PENDING → SETTLED + locked_amount decrement); backend HF buffer (`risk.borrow_buffer_bps`, default 100); FILLED-but-unsettled HF gap closure via `MatchRepository.getPendingBorrowMatches`. Reference: [`order-lock-lifecycle-followups.md`](./archive/order-lock-lifecycle-followups.md). |
| **Frontend M10 Phase 1 collateral toggle** | ✅ MOSTLY DONE | 3 hooks (`use-flag-collateral`, `use-flag-collateral-direct`, `use-unflag-collateral`), CollateralBadge + CollateralActions, centuari-hf-banner, use-asset-as-collateral-dialog, borrow-form collateral multi-select. **E2E gated** — see Track B1. |
| **Eager-write pattern (Phase A)** | ✅ DONE | Settlement-engine `apply-settlement.ts`, backend `apply-repay.ts`/`apply-withdraw-lend.ts`. Both writers stay byte-for-byte identical with indexer-v3 processors for C10 idempotency. |

**What this means:** the hub stack is functionally complete. Hub-only launch needs **polish + hardening + a few decisions**, not feature work.

---

## 3. Required for Hub-Only Launch

### Track A — Frontend Audit Backlog

Reference: [`frontend-revamp/docs/audits/2026-05-08-frontend-review/`](../../frontend-revamp/docs/audits/2026-05-08-frontend-review/)

Three lenses: pentest-style security audit, React 19 + Next 15 best-practices, CLAUDE.md convention compliance. 27 total issues. Submission order + dependency graph in [`issues/README.md`](../../frontend-revamp/docs/audits/2026-05-08-frontend-review/issues/README.md).

#### A1. CI / operational floor (ship first — unblocks everything)

| # | Severity | File | Description |
|---|---|---|---|
| 15 | **Critical operational** | `.github/workflows/deploy.yml` | Resolve unresolved git merge conflict markers in deploy.yml |
| 16 | **High** | CI + Dockerfile | Re-enable ESLint + TypeScript checks in CI and Docker build. Would have caught #18 (APR 100×), #22 (HF Infinity), #23 (viem dedupe), #25 (price 16 000×) |

#### A2. Critical security — deposit-flow trust gap (epic #0)

Real fund-loss vector: a backend-served bad `decimals` value can drain a user's wallet on approve.

| # | Severity | Description |
|---|---|---|
| 1 | foundation | Add hardcoded token allowlist module (`lib/token-allowlist.ts`) |
| 2 | **Critical** | Reject invalid ERC20 `decimals` from API |
| 3 | **Critical** | Validate `tokenAddress` with `viem.isAddress()` |
| 4 | **Critical** | Reject `tokenAddress` not in allowlist (deps #1 + #3) |
| 5 | **High** | Cross-check on-chain `decimals()` before approve (deps #2 + #3) |
| 6 | **High** | In-app pre-signature confirmation dialog (deps #1–#5) |

#### A3. High-severity correctness bugs

User-visible breakage on launch.

| # | Severity | Description |
|---|---|---|
| 7 | **High** | Tighten proxy path allowlist — `market`/`deposit`/`withdraw` allow arbitrary suffix |
| 18 | **High** | APR units inconsistent across normalizer / display / updater — likely live 100× bug |
| 22 | Medium (soft #16) | Health-factor Infinity-from-API + borrow/repay formula divergence bundle |
| 25 | **High** | Hardcoded prices: IDRX 16 000× wrong, XSGD 35% off; plus `amend-dialog.tsx` second source-of-truth |

#### A4. Medium-severity polish (10 items)

| # | Severity | Description |
|---|---|---|
| 8 | Medium | Authenticate faucet drip endpoint (no JWT today) |
| 9 | Medium | Fee logic divergence — dialogs over-display limit fees by 2× |
| 10 | Medium | Make wallet selection explicit (silent fallback to embedded in useDeposit) |
| 11 | Medium | Migrate 3 endpoints to apiClient (consistency + AuthError retry) |
| 12 | Medium | Validate Privy-sourced wallet addresses with isAddress() in useWalletAddress |
| 17 | Medium + Low | Docker / CI hardening bundle (`.dockerignore`, USE_MOCK guard, USER node, digest pin, EIP-6963 rdns, e2e dedup) |
| 19 | Medium | mapStatus silently coerces unknown order statuses to "OPEN" — fail loud |
| 21 | Medium | useOrderbook / useRecentTrades should not render with default decimals = 6 |
| 24 | Medium | Replace silent validation gates: borrow form, withdraw dialog, maturity dropdown |
| 26 | Medium | SubmitProofDialog half-built — Submit button has no handler; dropzone has no size/count bounds. **Path A** (finish, 3-4h with backend coordination) vs **Path B** (hide, ~10 min). Leaderboard-only — could defer past launch. |

#### A5. Low / preventive

| # | Description |
|---|---|
| 13 | Low-severity cleanup bundle (5 items — dead code, headers, env strictness) |
| 14 | Next.js config hardening + CI guard for Next.js version pin |
| 20 | Verify backend `DEV_TOKEN_<wallet>` auth path is disabled in production (tracking-only, backend coordination) |

### Track B — M10 Phase 1 close-out (hub-only)

| # | Status | Description |
|---|---|---|
| B1 | NOT STARTED | Unblock 8 skipped E2E collateral scenarios. Privy SDK 3.10.0 rejects stub JWTs → `preflightOrSkip()` in `frontend-revamp/e2e/collateral-toggle.spec.ts` skips all 8 cases at runtime. Three documented paths: (1) capture real Privy session via interactive login + `storageState`, (2) extend `**/auth.privy.io/**` route mock to match SDK session-refresh shape, (3) window-level test bypass in `useAuthToken.ts`. Path 1 recommended. See [`collateral-frontend-implementation.md`](./archive/collateral-frontend-implementation.md) "Privy session bypass for e2e tests" §. |
| B2 | NOT STARTED | Portfolio "Remove as collateral" button + 24h flag-lock countdown. CollateralManager.unflagFor works on hub today. Hook + UI both unbuilt. |
| B3 | DECISION | Launch with RiskModuleStub (rejects all unflag while debt > 0) or ship real RiskModule first. Stub means users can only unflag after full repay. See "Open Decisions" §5. |

### Track C — Order-lock lifecycle followups

Reference: [`order-lock-lifecycle-followups.md`](./archive/order-lock-lifecycle-followups.md)

| # | Status | Severity | Description |
|---|---|---|---|
| C1 | NOT STARTED | UX-only, no fund loss | **Engine-coordinated cancel** — eliminates ~10ms cancel-during-match race. Backend → engine NATS request/reply for cancel; engine pauses order in book; backend writes CANCELLED only on OK reply. **Optional pre-launch.** |
| C2 | NOT STARTED | Operational | **24h sweeper for stuck `matches.settlement_status='PENDING'`** — if settlement never lands (engine crash mid-batch, RPC outage exhausting retries), the match row is stuck PENDING and `portfolio.locked_amount` stays inflated forever. User's available balance under-counted until manual intervention. **RECOMMEND PRE-LAUNCH** — RPC outages happen. |

### Track D — Mainnet hardening (new work, not yet specced)

| # | Description |
|---|---|
| D1 | **Mainnet contract deploy plan** + ProxyAdmin transfer from burn-in deployer to multisig. Currently `PROXY_ADMIN = deployer EOA`; mainnet needs Safe multisig. |
| D2 | **Indexer-v3 hub-only config** — verify it runs with just the Arb mainnet ChainWatcher. Current config has 4 watchers (HUB + 3 spokes); needs `SPOKES=disabled` gate or per-chain enable flags. Spoke processors should not error in hub-only mode. |
| D3 | **Settlement-engine RPC failover** — confirm Viem fallback transport is configured for mainnet RPCs. Alchemy + Infura + QuickNode primary/secondary/tertiary. |
| D4 | **Prom metrics → dashboards + SLO alerts.** Metrics endpoint already exists on indexer-v3 + settlement-engine. Need Grafana dashboards + alert rules (settlement latency, indexer block lag, RPC error rate, sweeper-bot stale event — once sweeper exists). |
| D5 | **Privy mainnet config + Wagmi mainnet chain config** — verify staging Sepolia config doesn't bleed into prod env. `NEXT_PUBLIC_PRIVY_APP_ID` per env. |
| D6 | **Disable Faucet in prod build** — issue #8 covers JWT auth on faucet drip endpoint; mainnet needs full disable (no faucet route, no faucet UI). |
| D7 | **Mainnet token allowlist config** — issue #1 establishes the allowlist mechanism; mainnet token list needs explicit config (USDC `0xaf88…5831`, USDT, etc. mainnet addresses + decimals). |
| D8 | **Smart contract audit decision** — Phase 1 hub contracts have 339+ tests, **no external audit recorded**. Block launch on audit, or launch without and audit before mainnet TVL crosses a threshold? See "Open Decisions" §5. |

---

## 4. Suggested Phasing

Per the user's "phased execution across services — one phase at a time for review" preference. Each phase ends at a reviewable checkpoint.

| Phase | Scope | Why first |
|---|---|---|
| **0. CI floor** | A1 (#15, #16) | Unblocks every PR below — typecheck would have caught #18 / #22 / #25 |
| **1. Critical security** | A2 (#1–#6) | Real fund-loss vector pre-launch (deposit-flow trust gap) |
| **2. Correctness bugs** | A3 (#7, #18, #22, #25) | User-visible breakage — 100× / 16 000× wrong numbers |
| **3. M10 close-out** | B1, B2, B3 decision | Closes collateral UX cleanly without touching cross-chain UI |
| **4. Lock safety net** | C2 (stuck-PENDING sweeper) | Pre-launch operational requirement; RPC outages happen |
| **5. Mainnet hardening** | D1–D8 | Deploy plan + monitoring + RPC + audit decision |
| **6. Medium polish** | A4 (10 items) | Pre-launch cleanup — can run async with phase 5 |
| **Async / post-launch** | A5, C1, A4 #26 | Low-severity + leaderboard-only |

---

## 5. Open Decisions

These need explicit calls before phase 3+ can land.

1. **B3 — RiskModule at launch.** Options:
   - **(a) Launch with RiskModuleStub.** `canUnflag` returns `false` unconditionally. Users cannot unflag any collateralized asset while they hold any debt — they must repay in full first. UX requires explicit messaging ("repay in full to release this collateral"). Simpler. Already shipped.
   - **(b) Ship real RiskModule first.** Phase 2 RiskModule swap: oracle-backed HF math. Allows mid-life unflag if HF stays ≥ 1. Better UX. But requires real oracle integration + audit + governance timelock + governance call.
   - **Recommendation:** ship (a) at launch; defer (b) to first post-launch milestone. Stub is fail-closed, no fund-loss risk — only UX limitation.
2. **D8 — External smart contract audit.** Options:
   - **(a) Block launch on audit.** Engage firm (Spearbit, Trail of Bits, etc.), wait 6–8 weeks. Higher confidence pre-mainnet.
   - **(b) Launch testnet → mainnet without audit, schedule audit pre-TVL-threshold.** Faster to ship. Higher tail risk.
   - **Recommendation:** depends on launch timing + TVL expectations + capital. Discuss with team.
3. **A4 #26 — SubmitProofDialog.** Options:
   - **(a) Path A.** Finish: add `useSubmitProof` hook, POST to backend, tighten dropzone (`maxSize`, `maxFiles`), wire success/error UX. ~3–4h + backend endpoint.
   - **(b) Path B.** Hide: disable "Claim" trigger button with "coming soon" tooltip + add half-built comment. ~10 min.
   - **Recommendation:** if leaderboard is not Phase 1 critical-path, Path B; revisit Path A in a post-launch sprint.
4. **Phasing reorder.** Anything in §4 the team wants to resequence?

---

## 6. Cross-Chain References (for context)

Hub-only does not block on these, but they may come up during launch work:

- **Token allowlist (D7)** uses the cross-chain "Token × Chain Matrix" structure but filters to Arbitrum-only entries. Reference: `cross-chain-launch-plan.md` §10 token table.
- **Indexer-v3 (D2)** runs hub-only by disabling 3 ChainWatchers. Cross-chain processors stay in code but never see events. Reference: `cross-chain-launch-plan.md` §4.1.
- **Eager-write pattern (already shipped)** applies to both hub-only and cross-chain. Reference: `phase-a-settlement-engine-eager-writes.md` and `cross-chain-launch-plan.md` §4.5.

---

## 7. Definition of Done

Hub-only launch is shipped when:

- [ ] All Track A critical/high issues closed (Phase 0–2): #15, #16, #1–#7, #18, #22, #25
- [ ] Track B M10 close-out done: B1 (E2E unblocked), B2 (Remove as collateral button + countdown), B3 decision recorded
- [ ] Track C2 stuck-PENDING sweeper deployed
- [ ] Track D mainnet hardening complete: contracts deployed to Arbitrum One under multisig (D1), indexer hub-only configured (D2), RPC failover verified (D3), Grafana + alerts live (D4), Privy/Wagmi mainnet (D5), faucet disabled (D6), mainnet token allowlist set (D7), audit decision recorded (D8)
- [ ] End-to-end smoke test on Arbitrum One:
  - Deposit USDC via HubDepositor → `user_balance.available` increments → portfolio UI reflects within 2s
  - Place lend order → match against borrow → settlement batch lands → both portfolios reflect, locked_amount cleared
  - Flag asset as collateral → 24h lock active → countdown UI accurate
  - Attempt unflag before 24h → 409 FlagLockActive
  - Attempt withdrawal of flagged asset while in debt → reverts WithdrawalBlockedByHF
  - Full repay → debt clears, flags persist (per P1b-explicit). User can unflag after 24h once RiskModule.canUnflag returns true (stub: never; real: HF ≥ 1)

---

## 8. References

- [`cross-chain-launch-plan.md`](./cross-chain-launch-plan.md) — consolidated cross-chain plan (deferred work)
- [`phase-1-cross-chain-balance-ledger.md`](./archive/phase-1-cross-chain-balance-ledger.md) — original master plan (deep reference)
- [`order-lock-lifecycle-followups.md`](./archive/order-lock-lifecycle-followups.md) — Track C source
- [`collateral-loophole-fix-plan.md`](./archive/collateral-loophole-fix-plan.md) — collateral lifecycle background
- [`collateral-frontend-implementation.md`](./archive/collateral-frontend-implementation.md) — B3 RiskModule swap reference + B1 Privy e2e bypass paths
- [`phase-a-settlement-engine-eager-writes.md`](./archive/phase-a-settlement-engine-eager-writes.md) — eager-write pattern reference
- [`frontend-revamp/docs/audits/2026-05-08-frontend-review/`](../../frontend-revamp/docs/audits/2026-05-08-frontend-review/) — Track A source (action plan + 27 issue files)
