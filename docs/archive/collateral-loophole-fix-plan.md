# Closing the Off-Chain Collateral Flag Loophole

> **2026-05-14.** The hub-relevant collateral lifecycle (P1b-explicit model, HF buffer, pending-flag queue, RiskModule gating) is checklisted in [`hub-only-launch-plan.md`](../hub-only-launch-plan.md) Track B. Cross-chain implications are summarized in [`cross-chain-launch-plan.md`](../cross-chain-launch-plan.md) §9. This doc is kept as the deep design rationale + P0–P6 phasing history.

## Execution Phases (one service per phase — pause for review between each)

Execution is split per service boundary so each change set can be reviewed, tested, and merged independently. Do **not** start a phase until the previous one is reviewed.

| # | Phase | Status | Scope | Depends on |
|---|---|---|---|---|
| **P0** | **Docs** | ✅ DONE | Rewrote `phase-1-cross-chain-balance-ledger.md` Module 1/1b/2/4/8/9/10 + C1/C10. M1 status rolled back 🟢→🟡. New Module 1b section for `IRiskModule` + `RiskModuleStub` + `CollateralManager`. Postgres schema gained `flagged_at BIGINT`. Module 9 backend collateral module rewritten to `POST /collateral/unflag`. Module 10 frontend rewritten for borrow multi-select + countdown-gated unflag. | — |
| **P1a** | **Smart Contracts** | ✅ DONE (2026-04-09) | Extended `BalanceLedgerStorage` + `BalanceLedger` + `IBalanceLedger`; created `IRiskModule` + `RiskModuleStub` + `ICollateralManager` + `CollateralManagerStorage` + `CollateralManager`; 36 new Foundry tests (240/240 total passing); storage snapshot frozen at 49 slots; `DeployCollateralStack.s.sol` added. See "P1a Completion Record" below. | P0 |
| **P1b-core** | **Smart Contracts — core loophole fix** | ✅ DONE (WithdrawalRegistry HF gate, M4 2026-04-12). Auto-flag/auto-unflag **reverted 2026-04-17** — see P1b-explicit below. | Per-user debt tracker `_activeDebtCount` (`CentuariStorage.sol:56`), `WithdrawalRegistry.canWithdraw` HF gate as first action of `requestWithdrawal` (`WithdrawalRegistry.sol:110-112`). Tests in `WithdrawalRegistry.t.sol`. | P1a ✅ + M4 ✅ |
| **P1b-explicit** | **Smart Contracts — explicit-flag plumbing** | ✅ DONE (2026-04-17) | Removed implicit auto-flag at settlement and auto-unflag on repay. Added `address[] collateralAssets` to `ISettlement.MatchData`; `Settlement._processMatch` forwards it; `Centuari.settleMatch` iterates and calls `markCollateral` only for the assets the borrower explicitly requested. `Centuari.repay` no longer touches flags. Supersedes the previous P1b-ext multi-asset plumbing scope. | P1b-core ✅ |
| **P2** | **Matching Engine** | ✅ DONE (2026-04-28) | `collateralAssets: string[]` added to `borrowMarketOrderSchema` + `borrowLimitOrderSchema` (default `[]`); `borrowerCollateralAssets` added to `matchSchema`; `recordMatch()` and the `matchAgainstBook` call site forward the borrower's selection onto every fill (idempotent across partial fills). Redis stream serializer (`redis-service.ts`) JSON-encodes the array; `db-writer-service.ts` `fieldsToMatch` decodes it. 505/505 jest tests pass; 9 new test cases (4 schema, 4 engine propagation, 1 snapshot round-trip, 1 publisher round-trip). | P1b-explicit ABI ✅ + M9 backend collateral ✅ |
| **P3** | **Settlement Engine** | ✅ DONE (2026-04-28) | Settlement-engine reads `borrowerCollateralAssets` off each parsed match, dedupes per borrower within the batch, and encodes them into `MatchData.collateralAssets` for `Settlement.settleMatches` ([processBatch.ts:160-215](../../../settlement-engine/src/settlement/processBatch.ts), [smartContract.ts:228-267](../../../settlement-engine/src/settlement/smartContract.ts)). On settlement success, `clearPendingCollateralFlagsFromReceipt` ([apply-settlement.ts:410](../../../settlement-engine/src/settlement/database/apply-settlement.ts)) DELETEs the matching rows from the backend's `pending_collateral_flags` queue based on the receipt's `CollateralFlagSet` events. | P1b-explicit ABI ✅ + P2 ✅ |
| **P4** | **Backend** | ✅ DONE¹ | `backend-v2/src/collateral/` ships `collateral.controller.ts` + `collateral.service.ts` exposing `POST /collateral/flag` and `POST /collateral/unflag` driven by `CollateralManager.{flagFor,unflagFor}` with the protocol settlement key, both calling `applyOnChainEffect` inline (C10). The legacy `/internal/collateral` relay is gone. ¹ The pending-flag-queue branch of `POST /collateral/flag` (when the user already has a pending borrow) is the only sub-piece still deferred — it is the consumer of the P2/P3 plumbing and lands when those phases ship. | P1a + indexer-v3 existing (M8 start) |
| **P5** | **Indexer** | ✅ DONE | `handleCollateralFlagSet` is wired in `indexer-v3/src/processors/balance-ledger.processor.ts` against the canonical 5-param `CollateralFlagSet(writer, user, asset, used, flaggedAt)` shape and stamps `applied_by_tx_hash` / `applied_by_log_index` / `applied_by_block_hash` / `applied_by_block_number` for C10 idempotency. Tail short-circuits on rows already stamped with the matching tx hash. Per P1b-explicit, `Centuari.repay` no longer emits `CollateralFlagSet`, so no tail-only flag events exist from that path. | P1a events + M8 start |
| **P6** | **Frontend** | 🟡 IN PROGRESS | Borrow-form collateral asset multi-select **landed** in `centuari-borrow-dialog.tsx` (`collateralTokenList` + `selectedCollaterals`). **Still pending:** portfolio row countdown + disabled "Remove as collateral" button, `use-unflag-collateral.ts` hook, error surfacing for `FlagLockActive` / `WouldMakeUnhealthy`, e2e coverage. | P4 API + M10 start |

**Current module state per doc (as of 2026-04-28):** M1 🟢 DONE, M1b 🟢 DONE (both landed 2026-04-09). M2–M3 🟢 DONE. M4 🟢 DONE (landed 2026-04-12). **P1b-core HF gate is DONE**; the auto-flag at settlement and auto-unflag on repay that originally landed in M2 have been **reverted 2026-04-17** under P1b-explicit, because collateral selection is a user decision and must not be an implicit protocol side-effect. **P1b-explicit is DONE** — `ISettlement.MatchData` now carries `address[] collateralAssets` and `Centuari.settleMatch` flags only what the borrower explicitly requested; `Centuari.repay` never touches flags. M5 🟢 DONE (438/438 tests). M8 🟡 IN PROGRESS — indexer-v3 substantively landed; **unit-test substrate landed 2026-04-27** (61/61 jest cases across processors, core, migrations) but live spoke / `lzReceive` / Centuari-positions burn-in still pending. M7 ⚪ NOT STARTED. M9 / M10 🟡 IN PROGRESS — see the per-stream sub-tables in `phase-1-cross-chain-balance-ledger.md`. **P4 backend collateral endpoints and P5 indexer `CollateralFlagSet` processor are now DONE** (the pending-flag-queue branch of P4 is the only piece still deferred and rides on P3). **P6 frontend is IN PROGRESS** — borrow-form multi-select shipped, portfolio unflag UI still pending. **P2 (matching engine) is now DONE (2026-04-28)** — borrow-order schema carries `collateralAssets`, match payload carries `borrowerCollateralAssets`, Redis stream serializer/deserializer JSON-encodes the array, 505/505 tests pass. **P3 (settlement engine) is now DONE (2026-04-28)** — `MatchData.collateralAssets` is encoded per borrower in `transformMatchToContractFormat` and the `pending_collateral_flags` queue is cleared on settlement success via the receipt's `CollateralFlagSet` events. This plan file is the durable reference; phases land over time.

## Resuming in a new session

If you are picking this up in a fresh Claude session, the loophole fix is **mostly landed**:

- **P0 docs**: ✅ shipped.
- **P1a smart-contract primitives**: ✅ shipped — `BalanceLedger` now carries the on-chain flag, `CollateralManager` + `RiskModuleStub` exist, all tests green. M1 will redeploy as part of the next testnet cut that picks up the new layout.
- **P1b-core smart-contract wiring**: partial — only the `WithdrawalRegistry.canWithdraw` HF gate (`WithdrawalRegistry.sol:110-112`, M4 2026-04-12) and `_activeDebtCount` debt tracker (`CentuariStorage.sol:56`) remain. The auto-flag at `Centuari.settleMatch` and auto-unflag loop in `Centuari.repay` that originally landed in M2 were **reverted 2026-04-17** as part of P1b-explicit.
- **P1b-explicit smart-contract wiring**: ✅ shipped (2026-04-17). Design correction: protocol must never mutate a user's collateral flag implicitly. `ISettlement.MatchData` gained `address[] collateralAssets`; `Settlement._processMatch` forwards it; `Centuari.settleMatch` iterates and calls `markCollateral` only for the assets the borrower explicitly requested. `Centuari.repay` no longer calls `unmarkCollateral`. Standalone flag/unflag still flow through `CollateralManager.flagFor` / `CollateralManager.unflagFor` (unchanged).
- **Phase status as of 2026-04-28:**
  - **P2** → ✅ **DONE (2026-04-28)**. `collateralAssets: string[]` added to borrow-order schemas (default `[]`); `borrowerCollateralAssets` added to `matchSchema`; `recordMatch()` and the `matchAgainstBook` call site in `matching-engine.ts` thread the borrower's selection onto every match (preserved across partial fills). Redis stream JSON-encodes the array via `redis-service.ts` `matchToFields`; `db-writer-service.ts` `fieldsToMatch` decodes it via a small `parseCollateralAssets` helper. 505/505 jest tests pass; 9 new test cases lock in the contract (4 schema, 4 engine propagation, 1 snapshot round-trip, 1 publisher round-trip).
  - **P3** → ✅ **DONE (2026-04-28)**. Settlement engine reads `borrowerCollateralAssets` off each parsed match, dedupes per borrower within the batch, and encodes them into `MatchData.collateralAssets` for `Settlement.settleMatches` ([processBatch.ts:160-215](../../../settlement-engine/src/settlement/processBatch.ts), [smartContract.ts:228-267](../../../settlement-engine/src/settlement/smartContract.ts)). The `pending_collateral_flags` queue is cleared on settlement success by `clearPendingCollateralFlagsFromReceipt` ([apply-settlement.ts:410](../../../settlement-engine/src/settlement/database/apply-settlement.ts)) via the receipt's `CollateralFlagSet` events.
  - **P4 backend** → ✅ **DONE** (except the pending-flag-queue branch, which lands with P3). `backend-v2/src/collateral/` exposes `POST /collateral/{flag,unflag}` driven by `CollateralManager.{flagFor,unflagFor}` with `applyOnChainEffect` C10 stamping. Legacy `/internal/collateral` relay deleted.
  - **P5 indexer** → ✅ **DONE**. `handleCollateralFlagSet` wired in `indexer-v3/src/processors/balance-ledger.processor.ts` against the 5-param event shape with full C10 stamps.
  - **P6 frontend** → 🟡 **IN PROGRESS**. Borrow-form multi-select landed in `centuari-borrow-dialog.tsx`. Portfolio unflag UI + countdown + `use-unflag-collateral.ts` hook + e2e specs still pending. The frontend hook `use-set-collateral.ts` still calls the legacy `PUT /portfolio/is-collateral` endpoint and needs rewriting against `POST /collateral/{flag,unflag}` once the portfolio UI lands.

**Next actionable phase:** the **P4 backend pending-flag-queue enqueue branch** — when `POST /collateral/flag` is called while the user already has a pending borrow, the row needs to be written to `pending_collateral_flags` so settlement-engine's already-shipped P3 dequeue/clear path picks it up. After that closes, **P6 frontend portfolio unflag UI** unlocks. M7 (sweeper-bot) remains independent and unblocked.

**Critical context a new session needs to know:**
- P1a deviated from the original plan in three places. Update any future plan against reality, not the plan as originally written:
  1. `CollateralManager` uses `OwnableUpgradeable + onlyOperator` (matching `Settlement.sol` repo convention), **not** `AccessControlUpgradeable + OPERATOR_ROLE`. There is no `grantRole` step anywhere — governance sets the operator via `CollateralManager.setOperator(addr)`.
  2. `CollateralManager` added `MAX_FLAG_LOCK = 30 days` ceiling + `FlagLockTooLong` error (defensive, not in original spec).
  3. `CollateralFlagSet` event has **5 indexed/unindexed params** `(writer, user, asset, used, flaggedAt)`, not 4. P5 indexer + P4 backend decoders must match this shape.
- `RiskModuleStub.canUnflag` is **unconditionally false** — it ignores debt entirely because `Centuari.sol` has no per-user debt aggregator. Until Phase 2 swaps in the oracle-backed real `RiskModule`, **no Phase 1 path unflags a collateralized asset while the user still has any debt**. Full repayment no longer clears flags automatically; the user must explicitly invoke the `CollateralManager.unflagFor` path (which Phase 1 stub rejects), and Phase 2 will change that to a proper HF check. This is intentional: collateral lifecycle mirrors user intent, not protocol side-effects.
- `markCollateral` is idempotent and **does NOT refresh `_flaggedAt` on repeat** — verified by `test_RepeatedMark_DoesNotExtendLock` and `test_settleMatch_repeatFlagDoesNotRefreshTimestamp`. This is load-bearing for the 24h flag-lock and must be preserved through any future edits.
- The storage layout is frozen at `test/snapshots/BalanceLedger.storage.json`. Any future post-P1 edits to `BalanceLedgerStorage` must only append + shrink `__gap`.
- **`ISettlement.MatchData` carries `address[] collateralAssets`** (2026-04-17). The protocol never flags or unflags implicitly: `Centuari.settleMatch` iterates `collateralAssets` and calls `markCollateral` per entry (empty array = no-op), and `Centuari.repay` no longer touches flags at all. Off-chain (matching engine, settlement engine, backend) is responsible for queueing the user's pending flag requests and attaching them to each settlement; that plumbing is tracked under P2/P3/P4 and is out of scope for the smart-contract layer.

**Why P1 splits into P1a, P1b-core, and P1b-explicit:** exploration of `/smart-contract-revamp/src/` confirmed that (a) `Settlement.sol` did not currently call `BalanceLedger` at all — wiring was M2 work; (b) `Centuari.sol` did not depend on `BalanceLedger` and had no `totalDebt(user)` aggregator, only per-market `_borrowDebt[marketId][borrower]` — wiring was M2 work; (c) `WithdrawalRegistry.sol` did not exist — creation was M4 work. P1a landed the **self-contained** collateral primitives (storage, mutators, event, CollateralManager, RiskModuleStub) with isolated Foundry tests. **P1b-core** kept the per-user debt tracker `_activeDebtCount` and the `WithdrawalRegistry.canWithdraw` HF gate as the first action of `requestWithdrawal`. **P1b-explicit (2026-04-17) replaced the auto-flag/auto-unflag behavior that originally landed in M2**: the protocol no longer mutates a user's collateral selection as a side-effect of borrowing or repaying. `MatchData.collateralAssets` carries explicit flag requests from the off-chain layer; `CollateralManager` remains the only unflag path. This collapses the previously planned P1b-ext (multi-asset plumbing) into the same change and leaves the remaining work on the off-chain services (P2/P3/P4/P6).

### Design rationale — why auto-flag and auto-unflag were wrong

The original M2 design tied collateral to the loan token of the current borrow: settling a match implicitly flagged the borrowed token as collateral, and repaying to zero implicitly unflagged every asset. Two problems:

1. **Collateral is a user decision, not a settlement side-effect.** A user might deposit BTC, USDC, and ETH, and only want BTC flagged as collateral while borrowing USDC. Auto-flagging the loan token (USDC) incorrectly treats the borrowed asset itself as collateral and never consults the user's intent. Worse, it cannot represent the common case where collateral and loan token differ.
2. **Auto-unflag on repay bypasses the 24h flag-lock and the RiskModule gate.** Every other unflag path flows through `CollateralManager.unflagFor`, which enforces `FlagLockActive` and `RiskModule.canUnflag`. The repay short-circuit called `BalanceLedger.unmarkCollateral` directly, violating the "single on-chain policy seam" invariant and creating a sequence (flag → partial repay → full repay → immediate unflag) that could sidestep gates other callers must respect.

The fix: flag mutations are always explicit. At settlement time, the borrower's pending flag requests ride on `MatchData.collateralAssets` and are fulfilled by `Centuari.settleMatch` via the idempotent `markCollateral` primitive. Mid-life flag/unflag go through `CollateralManager`. Repay is purely a debt-settlement operation and does not touch `BalanceLedger`'s collateral state.

---

## P1a Completion Record (self-contained smart-contract primitives)

**Shipped 2026-04-09** — preserved below for audit. All file paths are relative to the smart-contract repo root (`smart-contract-revamp/`).

**Files landed:**

1. **`src/core/balance-ledger/BalanceLedgerStorage.sol`** — added `EnumerableSet` import, three new storage slots (`_usedAsCollateral`, `_flaggedAssets`, `_flaggedAt`), shrank `__gap[45]` → `__gap[42]`. Frozen layout: 49 total slots, unchanged from M1.
2. **`src/core/balance-ledger/BalanceLedger.sol`** — added `markCollateral` (idempotent, does NOT refresh `_flaggedAt`), `unmarkCollateral` (idempotent), and the three views. All gated `onlyAuthorizedWriter whenNotPaused`. Both mutators delegate to an internal `_setCollateralFlag(user, asset, used)` helper that owns the state transitions in one place. (Post-landing cleanup: a `setUsedAsCollateral(user, asset, bool)` wrapper briefly existed as a speculative Phase 6 integrator entry point but was removed — it had no production consumers and `mark`/`unmark` cover every real caller.)
3. **`src/interfaces/IBalanceLedger.sol`** — added `CollateralFlagSet(writer, user, asset, used, flaggedAt)` event (5 params; writer/user/asset indexed) and the six collateral surface signatures.
4. **`src/interfaces/IRiskModule.sol`** (new) — `canUnflag(user, asset)` + `canWithdraw(user, asset, amount)`.
5. **`src/core/risk/RiskModuleStub.sol`** (new) — Centuari-independent, fail-closed. `canUnflag` always false; `canWithdraw` mirrors `!usedAsCollateral`. Constructor takes `balanceLedger` + reverts on zero.
6. **`src/interfaces/ICollateralManager.sol`** (new) — events `OperatorUpdated` / `RiskModuleUpdated` / `FlagLockUpdated`; errors `ZeroAddress`, `NotOperator`, `NotFlagged`, `FlagLockActive(uint64)`, `WouldMakeUnhealthy`, `FlagLockTooLong`.
7. **`src/core/collateral/CollateralManagerStorage.sol`** (new) — `_balanceLedger`, `_riskModule`, `_operator`, `_flagLock` (uint64) + `uint256[46] __gap`.
8. **`src/core/collateral/CollateralManager.sol`** (new) — `Initializable + OwnableUpgradeable + CollateralManagerStorage + ICollateralManager`. Single `onlyOperator` modifier matching `Settlement.sol` convention (NOT `AccessControlUpgradeable`). Public `MAX_FLAG_LOCK = 30 days` constant, `setFlagLock` reverts `FlagLockTooLong` above it. `initialize(owner, operator, balanceLedger, riskModule)` seeds `_flagLock = 24 hours`. `unflagFor` runs the NotFlagged → FlagLockActive → canUnflag → unmark sequence.
9. **`script/DeployCollateralStack.s.sol`** (new) — deploys `RiskModuleStub` + `CollateralManager` proxy, then calls `BalanceLedger.forceAddWriter(mgr)` for the testnet fast path. Expects an already-deployed BalanceLedger. Does NOT touch `run-all.sh`.
10. **`test/balance-ledger/BalanceLedger.t.sol`** — +11 collateral tests (mark/stamp, idempotent-no-refresh, unmark, unmark idempotent, flaggedAssetsOf set semantics, unauthorized mark/unmark, pause blocks mark, zero-address reverts).
11. **`test/risk/RiskModuleStub.t.sol`** (new) — 7 tests (constructor zero-revert, canUnflag always false including when flagged, canWithdraw true/false, ignores amount, interface sanity).
12. **`test/collateral/CollateralManager.t.sol`** (new) — 17 tests including the load-bearing `test_RepeatedMark_DoesNotExtendLock` and a `PermissiveRiskModule` helper contract to isolate the happy-path unflag from the stub's fail-closed policy.
13. **`test/snapshots/BalanceLedger.storage.json`** (new) — committed storage layout snapshot.

**Verification results (run 2026-04-09):**
- `forge build` — clean, one benign lint note on `balanceLedger` immutable casing (intentional, matches external API).
- `forge test` — **240 passed, 0 failed, 0 skipped** across 8 suites. Breakdown of collateral-related tests: BalanceLedger suite 41 (29 pre-existing + 12 new), RiskModuleStub suite 7, CollateralManager suite 17.
- `forge inspect BalanceLedger storageLayout --force` — confirms slots 0–6 named + `__gap[42]` at slot 7, total 49 slots, matches M1 budget.

**Deviations from original plan (worth auditing):**
- CollateralManager uses `OwnableUpgradeable + onlyOperator`, not `AccessControlUpgradeable + OPERATOR_ROLE`. Rationale: matches `Settlement.sol` repo convention discovered during exploration. No `grantRole` plumbing anywhere.
- Added `MAX_FLAG_LOCK = 30 days` ceiling + `FlagLockTooLong` error not in original spec. Prevents a fat-fingered governance tx from effectively disabling unflagging.
- `CollateralFlagSet` event has 5 params `(writer, user, asset, used, flaggedAt)` — plan originally specified 4. P5 indexer decoder must match the 5-param shape. `flaggedAt` is `0` on unmark (sentinel).
- `ICollateralManager.sol` + `CollateralManagerStorage.sol` were added as separate files (not in the original deliverables list) to match the repo's interface-first + storage-contract pattern.
- Deploy script is a Foundry script (`script/DeployCollateralStack.s.sol`), not a `bin/` shell wrapper, and does NOT integrate into `run-all.sh` because `BalanceLedger` itself isn't in `run-all.sh` yet either. Integration is M1 redeploy plumbing.
- `RiskModuleStub.canUnflag` is unconditionally `false` (not `totalDebt == 0`) because `Centuari.sol` has no per-user debt aggregator and adding one was out of scope.

**Out of scope for P1a (subsequent landing status):**
- Modifying `Settlement.MatchData` or `Settlement._processMatch` — ✅ **landed 2026-04-17 as P1b-explicit**. `MatchData` now carries `address[] collateralAssets`; `_processMatch` forwards it.
- Adding a per-user open-market set or `hasOutstandingDebt` view to `Centuari.sol` — ✅ **landed in M2** as `_activeDebtCount` (`CentuariStorage.sol:56`) with the external view.
- Modifying `Centuari.repay` to call `BalanceLedger.unmarkCollateral` — ✅ **briefly landed in M2**, then **reverted 2026-04-17**. The correct design is that repay never touches flags; unflag goes through `CollateralManager.unflagFor`.
- Creating `WithdrawalRegistry.sol` — ✅ **landed in M4** with the `IRiskModule.canWithdraw` HF gate as the first action of `requestWithdrawal` (`WithdrawalRegistry.sol:110-112`).

---

## Context

The current Phase 1 design (`phase-1-cross-chain-balance-ledger.md`, Module 1 "Why the flag is off-chain", C1, Module 2) originally kept the `usedAsCollateral` opt-in flag in indexer-v3's Postgres, written by the backend only. The stated reasons were:

1. **Zero user signatures after deposit** — users never sign anything except the initial deposit tx.
2. **Protocol pays all non-deposit gas** — all other mutations go through the protocol's settlement key.
3. **Spam economics** — if toggling were on-chain and protocol-paid, a user could drain the settlement key's gas budget by flipping a boolean.
4. **Phase 1 has no on-chain consumer** — no RiskModule, no LiquidationEngine, no Phase 6 `CentuariRouter` yet.

### The loophole

`WithdrawalRegistry.sol` is deliberately **on-chain and permissionless** ("exit is always permissionless"). That is a load-bearing trust property: users trust the sequencer because they can always exit without it. This means any user — "app user" routed through the backend OR an "on-chain integrator" (Phase 6) calling the contract directly — can hit `WithdrawalRegistry.requestWithdrawal(user, asset, amount, targetChainId)` and pull their `available` balance out.

If the collateral flag lives in Postgres:

1. User deposits USDC, flags it as collateral **off-chain** via backend → Postgres row set.
2. User borrows BTC via the off-chain matching engine. Backend's HF check passes because USDC collateral is present. On settlement, debt is recorded on-chain in `Centuari.sol`, BTC credited to `BalanceLedger.available`.
3. User bypasses the backend, calls `WithdrawalRegistry.requestWithdrawal` directly from their wallet to withdraw USDC.
4. `WithdrawalRegistry` has **no way to read the Postgres flag**. It sees `BalanceLedger.available[user][USDC] >= amount`, authorizes the withdrawal, LayerZero-dispatches it to the target chain.
5. User walks away with BTC + USDC. Protocol eats the bad debt.

Phase 1 explicitly defers the RiskModule ("Phase 1 has no RiskModule yet, so the HF check is a no-op"), but the **design itself forecloses** an on-chain fix, because even once the RiskModule exists, it cannot read the Postgres flag from inside an on-chain `requestWithdrawal` call. And splitting users into "app users gated off-chain" vs "on-chain integrators gated on-chain" doesn't work: they both hit the same `WithdrawalRegistry`.

The goal: **one on-chain HF enforcement path that applies to every caller**, without reintroducing per-order user signatures and without opening a gas-spam vector on the protocol settlement key.

---

## Recommended Approach: On-chain flag with three write paths, all HF-gated at a single `RiskModule` seam

Move `usedAsCollateral` on-chain into `BalanceLedger`. Expose writer-gated `markCollateral` / `unmarkCollateral` primitives so Phase 6 on-chain integrators (`CentuariRouter`) can drive the flag directly. Add an auto-flag side effect inside `Settlement.settle()` so Phase 1 app users never sign or pay gas for the common case. Route **every** unflag — whether from an integrator, the backend, or a repay-to-zero — through a single `RiskModule.canUnflag(user, asset)` check so the "unflag while in debt iff HF stays healthy" capability has exactly one implementation seam that Phase 2 swaps out.

### State machine

| Trigger | Flag transition | HF check | Who pays gas | Signed by |
|---|---|---|---|---|
| User deposits USDC | stays `false` | n/a | user | user (deposit) |
| User requests "flag USDC" with no pending borrow | `false → true` via `CollateralManager.flagFor(user, USDC)` | none (flagging can only improve HF) | protocol | protocol settlement key |
| User requests "flag USDC" with a pending borrow | queued off-chain; attached to next `MatchData.collateralAssets`; fulfilled by `Centuari.settleMatch` via `markCollateral` | none | protocol | protocol settlement key |
| Subsequent borrow matches carrying the same flag request | no-op (idempotent; `_flaggedAt` preserved) | none | protocol | protocol |
| Borrow match settles with empty `collateralAssets` | **no flag mutation** | n/a | protocol | protocol |
| Full repay (`_activeDebtCount → 0` after repay) | **no flag mutation**; user must go through `CollateralManager.unflagFor` | n/a | protocol | protocol |
| App user taps "remove USDC as collateral" | `true → false` via `CollateralManager.unflagFor(user, asset)` | **`RiskModule.canUnflag(user, asset)` must return true; 24h flag-lock enforced** | protocol | protocol settlement key |
| Phase 6 `CentuariRouter` integrator flips flag for its caller | any | **same `RiskModule.canUnflag` gate, same 24h flag-lock** | integrator | integrator (their own model) |
| Spammy repeated toggles | bounded | 24h flag-lock + backend rate limit | — | — |

### The on-chain writers into `BalanceLedger`

1. **`Centuari.sol`** (explicit-flag fulfillment at match settlement) — **P1b-explicit ✅ DONE (2026-04-17).** Iterates `MatchData.collateralAssets` and calls `IBalanceLedger.markCollateral(borrower, asset)` for each. Empty array means no flag mutation. Idempotent warm SSTOREs after first use; `_flaggedAt` is never refreshed on repeat. No HF check needed (flagging can only improve HF).
2. **`CollateralManager.sol`** (standalone flag path) — **P1a ✅ DONE**. `flagFor(user, asset)` calls `markCollateral` unconditionally. Operator-gated; used when the user wants to flag without an accompanying borrow (or to re-flag after a prior unflag).
3. **`CollateralManager.sol`** (unflag path — the only one) — **P1a ✅ DONE**. `unflagFor(user, asset)` enforces: flag exists → `block.timestamp >= flaggedAt + 24h` → `riskModule.canUnflag(user, asset)` → `unmarkCollateral`. This is the single policy seam for clearing a flag; `Centuari.repay` no longer bypasses it.

### The `RiskModule` seam — one interface, two implementations

```solidity
interface IRiskModule {
    function canUnflag(address user, address asset) external view returns (bool);
    function canWithdraw(address user, address asset, uint256 amount) external view returns (bool);
}
```

- **Phase 1 stub (`RiskModuleStub.sol`)** — **P1a ✅ DONE**. `canUnflag` returns `false` unconditionally (Centuari-independent, fail-closed). `canWithdraw` returns `!balanceLedger.usedAsCollateral(user, asset)`. Under Phase 1 there is no on-chain unflag path for a flagged asset — the user must wait for Phase 2's real `RiskModule` to enable HF-based unflagging. (Before 2026-04-17 the `Centuari.repay` auto-unflag loop bypassed this, but that loop was removed as part of P1b-explicit because it violated the single-policy-seam invariant.)
- **Phase 2 real (`RiskModule.sol`):** reads on-chain debt + on-chain flagged assets via `balanceLedger.flaggedAssetsOf(user)` + on-chain balances + oracle prices, computes post-action HF, returns true iff HF ≥ 1e18 (+ safety margin). **Zero code changes in any caller** — `CollateralManager`, `WithdrawalRegistry`, and `CentuariRouter` all keep calling `riskModule.canUnflag` / `riskModule.canWithdraw` through the same interface. Phase 2 lands the new implementation, governance flips the pointer in `CollateralManager.riskModule` via the 48h timelock, and the "unflag while in debt iff HF stays safe" capability lights up automatically.

**Why put the HF gate in `CollateralManager` and `WithdrawalRegistry`, not in `BalanceLedger` itself:** `BalanceLedger` is the storage substrate and must stay upgrade-stable and writer-agnostic. Putting policy (HF gates, cooldowns, role checks) inside `BalanceLedger` would couple the storage layout to the Phase 2 RiskModule ABI and force a `BalanceLedger` upgrade every time policy changes. Keeping `BalanceLedger` as a dumb accounting contract (`markCollateral`/`unmarkCollateral` are writer-gated but unconditional) and concentrating policy in the caller contracts (`CollateralManager`, `WithdrawalRegistry`) means each policy layer can evolve on its own upgrade path, and Phase 6 integrators can either reuse `CollateralManager` or bring their own policy on top of the same storage.

### Spam defense on the new `CollateralManager.unflagFor` path

Because this path exists for app-user UX, it is protocol-signed — so it needs explicit anti-spam defense:

1. **24-hour flag-lock on-chain.** `BalanceLedger.markCollateral(user, asset)` stamps `flaggedAt[user][asset] = block.timestamp` every time the flag transitions `false → true`. `CollateralManager.unflagFor(user, asset)` requires `block.timestamp >= flaggedAt[user][asset] + 24 hours` and reverts with `FlagLockActive(unlocksAt)` otherwise. Applies uniformly to every unflag path — app-user backend, Phase 6 integrator, future manual admin.
   - **Idempotent mark does NOT refresh the stamp** — repeated borrows reusing the same collateral never extend the lockup. Verified by `test_RepeatedMark_DoesNotExtendLock`.
   - **Frontend popup at flag time (borrow form):** when the user places a borrow with `collateralAssets = [USDC]`, the frontend shows a confirmation modal explaining the 24h lock.
   - **No repay short-circuit.** As of 2026-04-17, `Centuari.repay()` does not touch flags. Full repayment leaves flags in place; the user must go through `CollateralManager.unflagFor` once the 24h lock expires and the RiskModule approves.
2. **Backend rate limit** in `backend-v2`: hard cap of 5 `POST /collateral/unflag` calls per user per 24h via Redis counter.
3. **No per-toggle fee in Phase 1.** The 24h lock makes spam economics degenerate.

### `WithdrawalRegistry` — single on-chain HF gate for every caller

`WithdrawalRegistry.requestWithdrawal(user, asset, amount, targetChainId)` calls `riskModule.canWithdraw(user, asset, amount)` as its first action. Reverts with `WithdrawalBlockedByHF()` if false. Phase 1 stub: rejects if `usedAsCollateral(user, asset)`. Phase 2 real: computes post-withdrawal HF and rejects if < 1.

This check is uniform for every caller — app users, integrators, direct-contract callers all hit it. That is what closes the loophole.

---

## Files to modify (by phase)

Paths are relative to the smart-contract repo root (`smart-contract-revamp/`) or the cross-service monorepo root where noted.

### P1a — ✅ DONE

See "P1a Completion Record" above.

### P1b-core — smart contracts (✅ HF gate only; auto-flag/auto-unflag reverted 2026-04-17)

Landed inside M2 (2026-04-10) and M4 (2026-04-12). File-level evidence for what remains:

- `src/core/centuari/Centuari.sol` — `settleMatch` takes `address[] calldata collateralAssets` and iterates `markCollateral` per entry; `repay` no longer calls `unmarkCollateral`. (Auto-flag and auto-unflag removed 2026-04-17; see P1b-explicit below.)
- `src/core/centuari/Centuari.sol` — `_activeDebtCount[borrower]` increment on new borrow / decrement when a market's debt hits 0. Retained for debt-state views/health checks even though it no longer drives an unflag loop.
- `src/core/centuari/CentuariStorage.sol:56` — `mapping(address => uint256) internal _activeDebtCount;` added; `__gap` shrunk to `uint256[40]`.
- `src/core/cross-chain/WithdrawalRegistry.sol:110-112` — `IRiskModule.canWithdraw` gate as the first action of `requestWithdrawal`, reverts `WithdrawalBlockedByHF()`.
- `test/cross-chain/WithdrawalRegistry.t.sol` — `test_RequestWithdrawal_BlockedByCollateralFlag` covers the HF gate rejection.

### P1b-explicit — smart contracts (✅ DONE 2026-04-17)

Supersedes the previously planned P1b-ext scope. The shipped changes:

- `src/interfaces/ISettlement.sol` — `MatchData` gained `address[] collateralAssets`.
- `src/interfaces/ICentuari.sol` — `settleMatch` signature gained `address[] calldata collateralAssets` as the final parameter.
- `src/core/settlement/Settlement.sol` — `_processMatch` forwards `matchData.collateralAssets` to `Centuari.settleMatch`.
- `src/core/centuari/Centuari.sol` — removed the unconditional `markCollateral(borrower, loanToken)`; now loops over `collateralAssets` and calls `markCollateral(borrower, collateralAssets[i])` per entry. Idempotent via `BalanceLedger`; re-submitting an already-flagged asset does not refresh `_flaggedAt`.
- `src/core/centuari/Centuari.sol` — removed the auto-unflag block inside `repay` (previously at lines 277-281). Repay is now purely debt settlement.
- `test/centuari/Centuari.t.sol` — rewrote `test_settleMatch_autoFlagsBorrowerCollateral` → `test_settleMatch_flagsRequestedCollateralAssets` + `test_settleMatch_doesNotFlagWhenCollateralAssetsEmpty`; rewrote `test_repay_autoUnflagsOnFullDebtClear` and `test_repay_unflagBypassesFlagLock` → `test_repay_neverUnflagsEvenOnFullDebtClear`; updated `test_repay_doesNotUnflagWithRemainingDebt` to pass flag requests explicitly.
- `test/settlement/Settlement.t.sol` — `MockCentuari.settleMatch` gained the `address[] calldata collateralAssets` param; `_createMatchData` emits `collateralAssets: new address[](0)`.

**Verification (run 2026-04-17):** `forge build` clean; `forge test` 438/438 passing across 17 suites.

### P2 — matching engine (✅ DONE 2026-04-28)

- `matching-engine/src/types/orders.ts` — `collateralAssets: z.array(ethereumAddressSchema).default([])` added to `borrowMarketOrderSchema` + `borrowLimitOrderSchema` only (lend schemas untouched). Empty default means in-flight orders parse cleanly.
- `matching-engine/src/types/matches.ts` — `borrowerCollateralAssets: z.array(ethereumAddressSchema).default([])` added to `matchSchema` next to `borrowerSettlementFeeAmount`.
- `matching-engine/src/core/execution-engine.ts` — `recordMatch()` parameter object extended with `borrowerCollateralAssets: string[]`, threaded into the constructed `Match`.
- `matching-engine/src/core/matching-engine.ts` — `matchAgainstBook()` pulls `collateralAssets` off whichever side of the match is the borrow order (mirrors the `borrowerWallet` split). Same array rides on every fill of a partial-fill borrow; settlement-engine deduplicates downstream when encoding.
- `matching-engine/src/services/redis-service.ts` — `matchToFields()` JSON-encodes `borrowerCollateralAssets` (Redis hashes are flat strings).
- `matching-engine/src/services/db-writer-service.ts` — `fieldsToMatch()` JSON-decodes via a small `parseCollateralAssets(raw)` helper that returns `[]` on missing/malformed input (symmetric with the schema default).
- Tests: factories default `collateralAssets`/`borrowerCollateralAssets` to `[]`; 9 new cases (4 schema, 4 engine propagation, 1 snapshot round-trip, 1 publisher round-trip). 505/505 jest tests pass.
- IDE plumbing: `matching-engine/tsconfig.json` now covers tests + adds `"types": ["jest","node"]`; `tsconfig.build.json` (new) is the test-free production build target referenced from `package.json` `build`/`dev` scripts.

### P3 — settlement engine (✅ DONE 2026-04-28)

- `settlement-engine/src/settlement/smartContract.ts:228-267` reads `borrowerCollateralAssets` off each parsed match (present on the Redis-stream payload thanks to P2), dedupes per borrower within a batch, and encodes into `MatchData.collateralAssets` for `Settlement.settleMatches`. Empty array means no flag mutation at settle.
- `settlement-engine/src/settlement/processBatch.ts:160-215` orchestrates the encoding step within the existing batch flow.
- The `pending_collateral_flags` queue is cleared on settlement success by `clearPendingCollateralFlagsFromReceipt` ([apply-settlement.ts:410](../../../settlement-engine/src/settlement/database/apply-settlement.ts)), which DELETEs matching rows based on each `CollateralFlagSet` event in the receipt. The indexer-v3 `balance-ledger.processor.ts` tail (P5) does the same DELETE idempotently for direct-caller events and any eager-path crashes — see phase-1 §C10.4.
- Receipt parsing carries the data needed to stamp via `applyOnChainEffect` from `@centuari-labs/on-chain-effects` ^0.2.0 (per phase-A A2). No new helper required.

### P4 — backend (blocked on M8 start; P1a done)

- `backend-v2/src/collateral/collateral.controller.ts` — **rewrite**. Delete the existing PUT `/internal/collateral` → indexer-v3 endpoint. New surface (all Privy JWT + 5/user/24h Redis rate limit). **Both endpoints are backend-direct: the handler submits the on-chain tx with the protocol settlement key, receives `txHash` from Viem, and calls `applyOnChainEffect` inline in the same request — no frontend confirmation endpoint, no frontend `txHash` handoff (see phase-1 §C10.1 / §C10.2).**
  - `POST /collateral/flag { asset }` — when the user has no pending borrow, submits `CollateralManager.flagFor(user, asset)` via the protocol settlement key, then calls `applyOnChainEffect` inline. When the user has a pending borrow, enqueues the flag request to a persistent `pending_collateral_flags` table so the settlement engine (P3) attaches it to the next match via `MatchData.collateralAssets`; in this branch there is no immediate on-chain tx and no `applyOnChainEffect` call — the row is written later by settlement-engine's inline helper call once the match settles, and the indexer tail as safety net.
  - `POST /collateral/unflag { asset }` — submits `CollateralManager.unflagFor(user, asset)` via the protocol settlement key, then calls `applyOnChainEffect` inline. Surface `FlagLockActive` / `WouldMakeUnhealthy` to the client with machine-readable error codes; on revert the DB is not mutated.
  - Imports `applyOnChainEffect` from `@centuari/indexer-v3/shared/apply-on-chain-effect` via pnpm workspace (phase-1 §C10.3). Package boundary: `"@centuari/indexer-v3": "workspace:*"` in `backend-v2/package.json`.
- `backend-v2/src/orders/` — no longer validates `collateralAssets` as required. If present, it is a convenience: the borrower may pass the list at borrow-order time and the backend enqueues it for fulfilment at settlement.

### P5 — indexer (blocked on M8 start; P1a done)

- `indexer-v3/src/processors/balance-ledger.processor.ts` — add `CollateralFlagSet` handler writing `user_balance.used_as_collateral` + `flagged_at` with full C10 idempotency stamps. Decoder MUST match the 5-param `(writer, user, asset, used, flaggedAt)` event shape.
- **Two-writer behavior (per phase-1 §C10.4):** when the tail decodes a `CollateralFlagSet` whose `(tx_hash, log_index)` is already stamped on the target row (eager path ran first), it is a no-op. The tail is the authoritative writer only when the eager path never ran — e.g., backend/settlement-engine crash between tx submit and `applyOnChainEffect`, or the never-eager branch where `POST /collateral/flag` enqueues a request and the eventual `settleMatch` emission is picked up by whichever writer gets there first.
- `indexer-v3/src/api/routes/collateral.ts` — **delete** (reads flow through `/portfolio/:user`).

### P6 — frontend (blocked on P4 + M10 start)

- `frontend-revamp/src/components/centuari-borrow/` — collateral asset multi-select on the borrow form. Confirmation modal on submit: *"These assets will be locked as collateral for at least 24 hours after the match settles. You will not be able to unflag them before then. Full repayment does NOT automatically release them — you must explicitly unflag after the 24h lock expires, and Phase 1's RiskModule will reject unflag while any debt remains. Continue?"* (Text reflects post-P1b-explicit behavior: repay never touches flags.)
- `frontend-revamp/src/components/centuari-portfolio/` — per-asset row with collateral badge, countdown timer (`flaggedAt + 24h - now`), and "Remove as collateral" button disabled until the countdown hits zero. Surface specific errors: `FlagLockActive` → shows unlock time; `WouldMakeUnhealthy` (Phase 1 stub) → "repay in full to release"; (Phase 2 real) → "would drop health factor below 1".
- `frontend-revamp/e2e/collateral-toggle.spec.ts` — cover: (a) flag appears automatically after a borrow match settles; (b) unflag button is disabled until `flaggedAt + 24h`; (c) unflag attempt via direct API call before 24h is rejected with `FlagLockActive`; (d) unflag attempt after 24h while still in debt is rejected in Phase 1 stub mode with `WouldMakeUnhealthy`; (e) full repay auto-clears the flag without waiting for the 24h.

---

## Verification

### P1a (already executed 2026-04-09)

- `forge build` — clean (one benign immutable-naming lint note).
- `forge test` — 240/240 passing across 8 suites.
- `forge inspect BalanceLedger storageLayout --force` — 49 slots, matches M1 budget.
- Storage snapshot committed at `test/snapshots/BalanceLedger.storage.json`.

### P1b-core + P1b-explicit (✅ executed) + end-to-end (pending)

1. **Unit tests (smart contracts):**
   - `forge test --match-contract BalanceLedger -vv` — existing + new mark/unmark tests all green. (✅ P1a)
   - `forge test --match-contract Centuari -vv` — explicit-flag at settle (empty-array and populated), idempotent `_flaggedAt` preservation, repay never unflags, `_activeDebtCount` bookkeeping. (✅ P1b-explicit, 2026-04-17)
   - `forge test --match-contract WithdrawalRegistry -vv` — flagged-with-debt reverts, flagged-no-debt passes. (✅ P1b-core, M4)
   - `forge test --match-contract Settlement -vv` — `MatchData.collateralAssets` round-trips through `_processMatch` into `Centuari.settleMatch`. (✅ P1b-explicit, 2026-04-17)

2. **Invariant fuzz test (future):** in a `cross-contract` test harness, fuzz sequences of (deposit, borrow with random `collateralAssets`, partial repay, full repay, attempt unflag, attempt withdraw). Assert:
   - `usedAsCollateral(user, asset) == true` implies the user explicitly requested flagging via either `CollateralManager.flagFor` or a past `MatchData.collateralAssets`, and `CollateralManager.unflagFor` has not since successfully cleared it.
   - `WithdrawalRegistry.requestWithdrawal` for a flagged asset with `totalDebt > 0` always reverts.
   - Repay does not change `usedAsCollateral` for any asset.
   - No sequence of calls lets a user withdraw a flagged asset while holding any debt.

3. **End-to-end on Arbitrum Sepolia** (after M2/M3/M4 redeploy with the new `MatchData` ABI):
   - Deposit USDC via `HubDepositor`.
   - Call `POST /collateral/flag { asset: USDC }` through the backend (no pending borrow). Backend submits `CollateralManager.flagFor(user, USDC)` with the protocol settlement key → receives `txHash` → calls `applyOnChainEffect` inline (verifies receipt `status=success` + `CollateralFlagSet(writer=CollateralManager, user, USDC, true, flaggedAt)` + args match) → stamps `user_balance` row with `applied_by_tx_hash / log_index / block_hash / block_number` in one pg transaction → responds 200. Frontend refetches portfolio and renders the flag immediately. Indexer tail later sees the same event → detects row already stamped with this `tx_hash` → no-op. Assert both the on-chain event and the stamped DB row.
   - Place a borrow order; confirm the match settles with the pre-existing flag untouched (empty `collateralAssets`) and no duplicate `CollateralFlagSet` event.
   - Alternative path: place a borrow with pending flag request for BTC (`collateralAssets=[BTC]`); confirm `CollateralFlagSet(writer=Centuari, user, BTC, true, flaggedAt)` fires at settlement.
   - **Flag-lock test (immediate):** less than 24h after flagging, call `POST /collateral/unflag { asset: USDC }`. Backend submits `CollateralManager.unflagFor(user, USDC)` with the protocol settlement key; tx reverts with `FlagLockActive(unlocksAt)`. `applyOnChainEffect` sees `receipt.status=reverted` and aborts without mutating the DB. Backend decodes the revert reason and surfaces "locked until {unlocksAt}" with HTTP 409 `FlagLockActive`.
   - **Direct withdrawal bypass test:** attempt `WithdrawalRegistry.requestWithdrawal(user, USDC, amount, arbChainId)` from a script bypassing the backend — assert it reverts with `WithdrawalBlockedByHF`.
   - **Full repay does NOT clear flag:** repay debt in full via `Centuari.repay` — confirm `activeDebtCount` drops to 0 and **no `CollateralFlagSet(..., false, ...)` event is emitted**. The flag must persist.
   - **Flag-lock test (after 24h, Phase 1 stub):** warp until `flaggedAt + 24h`, retry unflag — assert it reverts with `WouldMakeUnhealthy` (Phase 1 stub fail-closed).
   - **Backend rate-limit test:** call `POST /collateral/unflag` 10 times in 60 seconds — assert the 6th request is rejected with HTTP 429 and the protocol settlement key never submitted a tx for it.
   - **Phase 2 rehearsal:** deploy a mock `RiskModule` returning `canUnflag = true` for debt-free users; `governance.setRiskModule(mock)` via 48h timelock; confirm that AFTER the 24h flag-lock expires and after full repay, `CollateralManager.unflagFor` succeeds — validating zero-code-change Phase 2 swap.

4. **Regression:** run `backend-v2` test suite + `indexer-v3` migration tests to confirm the new collateral flag/unflag endpoints and the pending-flag queue do not break the module graph or leave dangling routes.
