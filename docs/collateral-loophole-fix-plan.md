# Closing the Off-Chain Collateral Flag Loophole

## Execution Phases (one service per phase — pause for review between each)

Execution is split per service boundary so each change set can be reviewed, tested, and merged independently. Do **not** start a phase until the previous one is reviewed.

| # | Phase | Status | Scope | Depends on |
|---|---|---|---|---|
| **P0** | **Docs** | ✅ DONE | Rewrote `phase-1-cross-chain-balance-ledger.md` Module 1/1b/2/4/8/9/10 + C1/C10. M1 status rolled back 🟢→🟡. New Module 1b section for `IRiskModule` + `RiskModuleStub` + `CollateralManager`. Postgres schema gained `flagged_at BIGINT`. Module 9 backend collateral module rewritten to `POST /collateral/unflag`. Module 10 frontend rewritten for borrow multi-select + countdown-gated unflag. | — |
| **P1a** | **Smart Contracts** | ✅ DONE (2026-04-09) | Extended `BalanceLedgerStorage` + `BalanceLedger` + `IBalanceLedger`; created `IRiskModule` + `RiskModuleStub` + `ICollateralManager` + `CollateralManagerStorage` + `CollateralManager`; 36 new Foundry tests (240/240 total passing); storage snapshot frozen at 49 slots; `DeployCollateralStack.s.sol` added. See "P1a Completion Record" below. | P0 |
| **P1b** | **Smart Contracts (deferred to M2/M4 start)** | 🔒 BLOCKED | Extend `Settlement.MatchData` with `collateralAssets[]`; add auto-flag loop inside `Settlement._processMatch`; add per-user open-market set + `hasOutstandingDebt` view in `Centuari.sol`; add auto-unflag loop inside `Centuari.repay`; create `WithdrawalRegistry.sol` with `riskModule.canWithdraw` gate. | P1a + M2 start + M4 start |
| **P2** | **Matching Engine** | 🔒 BLOCKED | Add `collateralAssets: string[]` to borrow order schema; forward unchanged in match payload. | P1b ABI + M9 start |
| **P3** | **Settlement Engine** | 🔒 BLOCKED | Encode `collateralAssets` per borrower into the `Settlement.settleMatches` ABI. | P1b ABI + P2 + M9 start |
| **P4** | **Backend** | 🔒 BLOCKED | Delete old `/internal/collateral` relay; add `POST /collateral/unflag` (Privy JWT, 5/user/24h Redis rate limit); add `collateralAssets` validation to borrow-order DTO; wire `CollateralManager.unflagFor` via protocol settlement key + `applyOnChainEffect`. | P1a + indexer-v2 existing (M8 start) |
| **P5** | **Indexer** | 🔒 BLOCKED | Add `CollateralFlagSet` processor writing `user_balance.used_as_collateral` + `flagged_at` with C10 idempotency stamps. | P1a events + M8 start |
| **P6** | **Frontend** | 🔒 BLOCKED | Borrow form collateral multi-select + 24h-lock confirmation modal; portfolio row countdown + disabled unflag button; error surfacing for `FlagLockActive` / `WouldMakeUnhealthy`. | P4 API + M10 start |

**Current module state per doc (as of 2026-04-10):** M1 🟢 DONE, M1b 🟢 DONE (both landed 2026-04-09; phase-1 doc updated to reflect this). M2–M10 not started; M2 is now **unblocked** and is the next priority. This plan file is the durable reference; phases land over time.

## Resuming in a new session

If you are picking this up in a fresh Claude session, the loophole fix is **partially landed**:

- **P0 docs**: ✅ shipped.
- **P1a smart-contract primitives**: ✅ shipped — `BalanceLedger` now carries the on-chain flag, `CollateralManager` + `RiskModuleStub` exist, all tests green. M1 will redeploy as part of the next testnet cut that picks up the new layout.
- **Every remaining phase is blocked on module starts**, not on prior code work:
  - **P1b** → wait for M2 (`Settlement`/`Centuari` wiring) and M4 (`WithdrawalRegistry` creation) to begin. When they do, P1b extends `Settlement.MatchData` with `collateralAssets[]`, adds auto-flag inside `_processMatch`, adds a per-user open-market set + `hasOutstandingDebt` to `Centuari`, wires auto-unflag inside `Centuari.repay`, and creates `WithdrawalRegistry` with the `riskModule.canWithdraw` gate.
  - **P2** → blocked behind P1b's ABI + M9 start (matching engine work).
  - **P3** → blocked behind P1b's ABI + P2 + M9 start (settlement engine encoding).
  - **P4 backend** → only gated on P1a (✅ DONE) + M8 start (indexer-v2). Becomes actionable the moment M8 kicks off. Scope: delete old `/internal/collateral` relay, add `POST /collateral/unflag` with Privy JWT + 5/user/24h Redis rate limit, add `collateralAssets` validation to borrow-order DTO, wire `CollateralManager.unflagFor` via protocol settlement key + `applyOnChainEffect`.
  - **P5 indexer** → only gated on P1a (✅ DONE) + M8 start. Scope: `CollateralFlagSet` processor writing `user_balance.used_as_collateral` + `flagged_at` with C10 idempotency stamps.
  - **P6 frontend** → blocked behind P4 + M10 start.

**Next actionable phases once modules unblock:** P4 and P5 (both only need M8 to begin). Everything else follows the dependency chain.

**Critical context a new session needs to know:**
- P1a deviated from the original plan in three places. Update any future plan against reality, not the plan as originally written:
  1. `CollateralManager` uses `OwnableUpgradeable + onlyOperator` (matching `Settlement.sol` repo convention), **not** `AccessControlUpgradeable + OPERATOR_ROLE`. There is no `grantRole` step anywhere — governance sets the operator via `CollateralManager.setOperator(addr)`.
  2. `CollateralManager` added `MAX_FLAG_LOCK = 30 days` ceiling + `FlagLockTooLong` error (defensive, not in original spec).
  3. `CollateralFlagSet` event has **5 indexed/unindexed params** `(writer, user, asset, used, flaggedAt)`, not 4. P5 indexer + P4 backend decoders must match this shape.
- `RiskModuleStub.canUnflag` is **unconditionally false** — it ignores debt entirely because `Centuari.sol` has no per-user debt aggregator. The only Phase 1 path to clear a flag is `Centuari.repay` auto-unflag (P1b work). App-user mid-life unflagging stays blocked until Phase 2 swaps in the oracle-backed real `RiskModule`.
- `markCollateral` is idempotent and **does NOT refresh `_flaggedAt` on repeat** — verified by `test_RepeatedMark_DoesNotExtendLock`. This is load-bearing for the 24h flag-lock and must be preserved through any future edits.
- The storage layout is frozen at `test/snapshots/BalanceLedger.storage.json`. Any future P1b / post-P1 edits to `BalanceLedgerStorage` must only append + shrink `__gap`.

**Why P1 splits into P1a and P1b:** exploration of `/smart-contract-revamp/src/` confirmed that (a) `Settlement.sol` did not currently call `BalanceLedger` at all — wiring is M2 work; (b) `Centuari.sol` did not depend on `BalanceLedger` and had no `totalDebt(user)` aggregator, only per-market `_borrowDebt[marketId][borrower]` — wiring is M2 work; (c) `WithdrawalRegistry.sol` did not exist — creation is M4 work. Touching any of those in P1a would bleed scope across modules that hadn't started. P1a landed the **self-contained** collateral primitives (storage, mutators, event, CollateralManager, RiskModuleStub) with isolated Foundry tests; P1b lands the wiring when M2/M4 spin up.

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

**Deviations from original plan (worth auditing before P1b starts):**
- CollateralManager uses `OwnableUpgradeable + onlyOperator`, not `AccessControlUpgradeable + OPERATOR_ROLE`. Rationale: matches `Settlement.sol` repo convention discovered during exploration. No `grantRole` plumbing anywhere.
- Added `MAX_FLAG_LOCK = 30 days` ceiling + `FlagLockTooLong` error not in original spec. Prevents a fat-fingered governance tx from effectively disabling unflagging.
- `CollateralFlagSet` event has 5 params `(writer, user, asset, used, flaggedAt)` — plan originally specified 4. P5 indexer decoder must match the 5-param shape. `flaggedAt` is `0` on unmark (sentinel).
- `ICollateralManager.sol` + `CollateralManagerStorage.sol` were added as separate files (not in the original deliverables list) to match the repo's interface-first + storage-contract pattern.
- Deploy script is a Foundry script (`script/DeployCollateralStack.s.sol`), not a `bin/` shell wrapper, and does NOT integrate into `run-all.sh` because `BalanceLedger` itself isn't in `run-all.sh` yet either. Integration is M1 redeploy plumbing.
- `RiskModuleStub.canUnflag` is unconditionally `false` (not `totalDebt == 0`) because `Centuari.sol` has no per-user debt aggregator and adding one was out of scope.

**Out of scope for P1a (still deferred to P1b, gated on M2/M4 start):**
- Modifying `Settlement.MatchData` or `Settlement._processMatch`.
- Adding a per-user open-market set or `hasOutstandingDebt` view to `Centuari.sol`.
- Modifying `Centuari.repay` to call `BalanceLedger.unmarkCollateral`.
- Creating `WithdrawalRegistry.sol`.

---

## Context

The current Phase 1 design (`phase-1-cross-chain-balance-ledger.md`, Module 1 "Why the flag is off-chain", C1, Module 2) originally kept the `usedAsCollateral` opt-in flag in indexer-v2's Postgres, written by the backend only. The stated reasons were:

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
| Borrow match settles, borrower declared USDC as collateral | `false → true`, **atomic inside `Settlement.settle()`** | none (flagging can only improve HF) | protocol | protocol settlement key |
| Subsequent borrow matches reusing the same collateral | no-op (idempotent) | none | protocol | protocol |
| Full repay (`totalDebt == 0` after repay) | `true → false`, **atomic inside `Centuari.repay()`** for every asset in `flaggedAssetsOf(user)` | none (no debt ⇒ trivially HF-safe) | protocol | protocol |
| App user taps "remove USDC as collateral" while still in debt | `true → false` via `CollateralManager.unflagFor(user, asset)` | **`RiskModule.canUnflag(user, asset)` must return true** | protocol | protocol settlement key |
| Phase 6 `CentuariRouter` integrator flips flag for its caller | any | **same `RiskModule.canUnflag` gate** | integrator | integrator (their own model) |
| Spammy repeated toggles | bounded | 24h flag-lock + backend rate limit | — | — |

### The three on-chain writers into `BalanceLedger`

1. **`Settlement.sol`** (auto-flag at match settlement) — P1b work. Extends the match payload with a `collateralAssets[]` per borrower and loops `markCollateral(borrower, asset)` inside `settle()`. Idempotent warm SSTOREs after first use. No HF check needed.
2. **`Centuari.sol`** (auto-unflag on repay-to-zero) — P1b work. After `repay()`, if `totalDebt(user) == 0`, loops over `flaggedAssetsOf(user)` and calls `unmarkCollateral` for each. No HF check needed.
3. **`CollateralManager.sol`** (unflag-while-in-debt path) — **P1a ✅ DONE**. Operator-gated wrapper enforcing the 24h flag-lock and `riskModule.canUnflag` gate.

### The `RiskModule` seam — one interface, two implementations

```solidity
interface IRiskModule {
    function canUnflag(address user, address asset) external view returns (bool);
    function canWithdraw(address user, address asset, uint256 amount) external view returns (bool);
}
```

- **Phase 1 stub (`RiskModuleStub.sol`)** — **P1a ✅ DONE**. `canUnflag` returns `false` unconditionally (Centuari-independent, fail-closed). `canWithdraw` returns `!balanceLedger.usedAsCollateral(user, asset)`. The only Phase 1 path to clear a flag is the auto-unflag loop inside `Centuari.repay` (P1b work).
- **Phase 2 real (`RiskModule.sol`):** reads on-chain debt + on-chain flagged assets via `balanceLedger.flaggedAssetsOf(user)` + on-chain balances + oracle prices, computes post-action HF, returns true iff HF ≥ 1e18 (+ safety margin). **Zero code changes in any caller** — `CollateralManager`, `WithdrawalRegistry`, and `CentuariRouter` all keep calling `riskModule.canUnflag` / `riskModule.canWithdraw` through the same interface. Phase 2 lands the new implementation, governance flips the pointer in `CollateralManager.riskModule` via the 48h timelock, and the "unflag while in debt iff HF stays safe" capability lights up automatically.

**Why put the HF gate in `CollateralManager` and `WithdrawalRegistry`, not in `BalanceLedger` itself:** `BalanceLedger` is the storage substrate and must stay upgrade-stable and writer-agnostic. Putting policy (HF gates, cooldowns, role checks) inside `BalanceLedger` would couple the storage layout to the Phase 2 RiskModule ABI and force a `BalanceLedger` upgrade every time policy changes. Keeping `BalanceLedger` as a dumb accounting contract (`markCollateral`/`unmarkCollateral` are writer-gated but unconditional) and concentrating policy in the caller contracts (`CollateralManager`, `WithdrawalRegistry`) means each policy layer can evolve on its own upgrade path, and Phase 6 integrators can either reuse `CollateralManager` or bring their own policy on top of the same storage.

### Spam defense on the new `CollateralManager.unflagFor` path

Because this path exists for app-user UX, it is protocol-signed — so it needs explicit anti-spam defense:

1. **24-hour flag-lock on-chain.** `BalanceLedger.markCollateral(user, asset)` stamps `flaggedAt[user][asset] = block.timestamp` every time the flag transitions `false → true`. `CollateralManager.unflagFor(user, asset)` requires `block.timestamp >= flaggedAt[user][asset] + 24 hours` and reverts with `FlagLockActive(unlocksAt)` otherwise. Applies uniformly to every unflag path — app-user backend, Phase 6 integrator, future manual admin.
   - **Idempotent mark does NOT refresh the stamp** — repeated borrows reusing the same collateral never extend the lockup. Verified by `test_RepeatedMark_DoesNotExtendLock`.
   - **Frontend popup at flag time (borrow form):** when the user places a borrow with `collateralAssets = [USDC]`, the frontend shows a confirmation modal explaining the 24h lock.
   - **Auto-unflag on repay-to-zero is exempt from the flag-lock.** `Centuari.repay()` calls `BalanceLedger.unmarkCollateral` directly (bypassing `CollateralManager`), so full repayment always clears flags regardless of how recently they were set.
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

### P1b — smart contracts (blocked on M2/M4 start)

- `src/core/settlement/Settlement.sol` — extend `MatchData` with `collateralAssets[]` per borrower; loop `markCollateral` inside `_processMatch`.
- `src/interfaces/ISettlement.sol` — update `MatchData` struct.
- `src/core/centuari/Centuari.sol` — add per-user open-market set + `hasOutstandingDebt(user)` view; after `repay()` when debt hits zero, iterate `flaggedAssetsOf(user)` and call `unmarkCollateral` for each.
- `src/core/centuari/CentuariStorage.sol` — add `EnumerableSet` for per-user open markets; shrink `__gap`.
- `src/core/cross-chain/WithdrawalRegistry.sol` **(new in M4)** — add `riskModule.canWithdraw` guard at the top of `requestWithdrawal`, emit `WithdrawalBlockedByHF` on revert.
- `test/settlement/Settlement.t.sol` — test match-with-collateral flips flag atomically.
- `test/centuari/Centuari.t.sol` — test repay-to-zero clears all flags bypassing the 24h lock.
- `test/cross-chain/WithdrawalRegistry.t.sol` — test stub blocks flagged withdrawal, allows unflagged, allows flagged after full repay.

### P2 — matching engine (blocked on P1b ABI + M9 start)

- `matching-engine/src/types/order.ts` — add `collateralAssets: string[]` to the borrow order schema.
- `matching-engine/src/services/*` — forward `collateralAssets` unchanged into the match payload.

### P3 — settlement engine (blocked on P1b ABI + P2 + M9 start)

- `settlement-engine/src/settlement/smartContract.ts` — include `collateralAssets` per borrower in the `settleMatches()` call encoding.

### P4 — backend (blocked on M8 start; P1a done)

- `backend-v2/src/collateral/collateral.controller.ts` — **rewrite**. Delete the existing PUT `/internal/collateral` → indexer-v2 endpoint. New surface:
  - `POST /collateral/unflag { asset }` — authenticated by Privy JWT (app user). Rate-limited to 5/user/24h via Redis counter. Calls `CollateralManager.unflagFor(user, asset)` via the protocol settlement key. Returns the tx hash and eagerly applies the DB mutation through the Module 8 `applyOnChainEffect` helper (C10 pattern).
  - No `POST /collateral/flag` for app users — flagging happens at borrow time via the match pipeline.
- `backend-v2/src/orders/` — add `collateralAssets` validation to borrow-order DTO (non-empty, must be assets the user holds).

### P5 — indexer (blocked on M8 start; P1a done)

- `indexer-v2/src/processors/balance-ledger.processor.ts` — add `CollateralFlagSet` handler writing `user_balance.used_as_collateral` + `flagged_at` with full C10 idempotency stamps. Decoder MUST match the 5-param `(writer, user, asset, used, flaggedAt)` event shape.
- `indexer-v2/src/api/routes/collateral.ts` — **delete** (reads flow through `/portfolio/:user`).

### P6 — frontend (blocked on P4 + M10 start)

- `frontend-revamp/src/components/centuari-borrow/` — collateral asset multi-select on the borrow form. Confirmation modal on submit: *"These assets will be locked as collateral for at least 24 hours after the match settles. You will not be able to unflag them before then, even after repaying partially. Full repayment will release them immediately. Continue?"*
- `frontend-revamp/src/components/centuari-portfolio/` — per-asset row with collateral badge, countdown timer (`flaggedAt + 24h - now`), and "Remove as collateral" button disabled until the countdown hits zero. Surface specific errors: `FlagLockActive` → shows unlock time; `WouldMakeUnhealthy` (Phase 1 stub) → "repay in full to release"; (Phase 2 real) → "would drop health factor below 1".
- `frontend-revamp/e2e/collateral-toggle.spec.ts` — cover: (a) flag appears automatically after a borrow match settles; (b) unflag button is disabled until `flaggedAt + 24h`; (c) unflag attempt via direct API call before 24h is rejected with `FlagLockActive`; (d) unflag attempt after 24h while still in debt is rejected in Phase 1 stub mode with `WouldMakeUnhealthy`; (e) full repay auto-clears the flag without waiting for the 24h.

---

## Verification

### P1a (already executed 2026-04-09)

- `forge build` — clean (one benign immutable-naming lint note).
- `forge test` — 240/240 passing across 8 suites.
- `forge inspect BalanceLedger storageLayout --force` — 49 slots, matches M1 budget.
- Storage snapshot committed at `test/snapshots/BalanceLedger.storage.json`.

### P1b + end-to-end (pending)

1. **Unit tests (smart contracts):**
   - `forge test --match-contract BalanceLedger -vv` — existing + new mark/unmark tests all green.
   - `forge test --match-contract Settlement -vv` — match-with-collateral test passes.
   - `forge test --match-contract Centuari -vv` — repay-to-zero clears flags.
   - `forge test --match-contract WithdrawalRegistry -vv` — flagged-with-debt reverts, flagged-no-debt passes, unflagged-with-debt passes.

2. **Invariant fuzz test:** in a `cross-contract` test harness, fuzz sequences of (deposit, borrow with random collateralAssets, partial repay, full repay, attempt withdraw). Assert:
   - `usedAsCollateral(user, asset) == true` implies `user` has had at least one borrow match reference `asset` and has not fully repaid since.
   - `WithdrawalRegistry.requestWithdrawal` for a flagged asset with `totalDebt > 0` always reverts.
   - No sequence of calls lets a user withdraw a flagged asset while holding any debt.

3. **End-to-end on Arbitrum Sepolia** (after M2/M3/M4 redeploy):
   - Deposit USDC via `HubDepositor`.
   - Place a borrow order with `collateralAssets = [USDC]` through the frontend.
   - Watch a match settle; confirm `CollateralFlagSet(writer, user, USDC, true, flaggedAt)` on-chain and in indexer.
   - **Flag-lock test (immediate):** less than 24h after settle, call `POST /collateral/unflag { asset: USDC }` — assert `CollateralManager.unflagFor` reverts with `FlagLockActive`, backend surfaces "locked until {timestamp}".
   - **Direct withdrawal bypass test:** attempt `WithdrawalRegistry.requestWithdrawal(user, USDC, amount, arbChainId)` from a script bypassing the backend — assert it reverts with `WithdrawalBlockedByHF`.
   - **Flag-lock test (after 24h):** warp until `flaggedAt + 24h`, retry unflag — assert it reverts with `WouldMakeUnhealthy` (Phase 1 stub fail-closed).
   - **Repay short-circuit test:** while the 24h lock is still active, call `Centuari.repay` for the full debt — confirm `CollateralFlagSet(writer, user, USDC, false, 0)` fires atomically via the auto-unflag loop **without waiting for the 24h**.
   - **Post-repay withdrawal:** retry the withdrawal; confirm it proceeds through PENDING → PROCESSING → COMPLETED.
   - **Backend rate-limit test:** call `POST /collateral/unflag` 10 times in 60 seconds — assert the 6th request is rejected with HTTP 429 and the protocol settlement key never submitted a tx for it.
   - **Phase 2 rehearsal:** deploy a mock `RiskModule` returning `canUnflag = true` unconditionally; `governance.setRiskModule(mock)` via 48h timelock; confirm that AFTER the 24h flag-lock expires, the unflag-while-in-debt path succeeds end-to-end — validating zero-code-change Phase 2 swap.

4. **Regression:** run `backend-v2` test suite + `indexer-v2` migration tests to confirm the deleted collateral module does not break the module graph or leave dangling routes.
