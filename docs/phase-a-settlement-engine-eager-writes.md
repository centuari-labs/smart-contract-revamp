# Phase A — Settlement-Engine Eager Writes (indexer-v3 schema)

## Status (as of 2026-04-27)

| Step | Status | Evidence |
|---|---|---|
| A1 — Capture full receipt metadata in settlement-engine | 🟢 DONE | `SettlementResult.blockHash` + per-event `logIndex` on `ParsedLendPosition` / `ParsedBorrowPosition` in `settlement-engine/src/settlement/smartContract.ts`. |
| A2 — Add the shared helper dep (`@centuari-labs/on-chain-effects ^0.2.0`) | 🟢 DONE | Vendored at repo root `on-chain-effects/` v0.2.0; both `settlement-engine/package.json` and `backend-v2/package.json` depend on `file:../on-chain-effects`. |
| A3 — Schema audit + (if needed) migration 005 | 🟢 DONE | No new migration needed; existing `lend_position` / `borrow_position` / `user_balance` / `market` columns sufficient. `bond_token` left to indexer tail. |
| A4 — Rewrite settlement-engine persistence | 🟢 DONE | `settlement-engine/src/settlement/database/apply-settlement.ts` replaces deleted `persistence.ts`; one `applyOnChainEffect` call per parsed event with explicit `logIndex`. `recovery.ts` retired (only `order-failure.ts` retained for matching-engine concerns). |
| A5 — Migrate backend-v2 onto the shared on-chain-state schema | 🟢 DONE | Portfolio reads run through `backend-v2/src/core/on-chain-state/` against shared `lend_position` / `borrow_position` / `user_balance` / `market` tables. Eager writes live in `apply-repay.ts` + `apply-withdraw-lend.ts` + `apply-internals.ts`, mirroring indexer-v3 SQL byte-for-byte. |
| A6 — Delete legacy backend-v2 UUID tables + entities + DROP TABLE migration | ⚪ NOT STARTED | Legacy entities still present: `LegacyPortfolio`, backend-v2-owned `LendPosition` / `BorrowPosition` / `Market`. No DROP TABLE migration exists in `backend-v2/src/core/database/migrations/`. The Legacy Deprecation Checklist in `phase-1-cross-chain-balance-ledger.md` (Phase A) tracks this as the only outstanding item for Phase A. |

The detailed plan below is preserved as the durable reference for the in-progress / outstanding work and for audit of what landed.

## Context

Settlement-engine today writes to **backend-v2's UUID-keyed schema** (`settlement_batches`, `settlement_items`, `lend_positions`, `borrow_positions`, `portfolio`, `matches`) using `settlement_batch_id + UNIQUE` constraints for idempotency. Indexer-v3 writes to a **parallel BYTEA-keyed schema** (`user_balance`, `market`, `lend_position`, `borrow_position`, `bond_token`) using `applied_by_tx_hash + applied_by_log_index` stamps.

That's two sources of truth for the same on-chain state. `applyOnChainEffect` only targets the indexer-v3 schema. Per the Phase-1 deprecation rule ("must be deleted in the same phase that introduces its replacement, no parallel old + new periods"), Phase A converges on indexer-v3 as the single schema.

**Decisions (confirmed by user):**
1. Settlement-engine writes **indexer-v3 schema only** via `applyOnChainEffect`. Backend-v2 UUID tables for settled state become legacy.
2. Migrate **only the backend-v2 reads that would break** (portfolio + positions APIs that the frontend consumes). Defer unrelated backend reads to Phase C.

---

## Scope

### In scope
- Rewrite settlement-engine's Phase-1+Phase-2 persistence onto `applyOnChainEffect` targeting indexer-v3 tables.
- Any schema gaps in indexer-v3 (columns the tail does not yet populate but settlement-engine needs to stamp): add via new migration.
- Repoint backend-v2 read endpoints that serve portfolio / lend-position / borrow-position data to the shared on-chain-state Postgres tables (`user_balance`, `lend_position`, `borrow_position`, `market`) via direct SQL through backend-v2's `DatabaseService` pool. (Earlier drafts said "indexer-v3 Fastify REST" — superseded; see A5 note. Indexer-v3 now exposes only `/health` + `/metrics`.)
- Delete the legacy backend-v2 UUID tables + their TypeORM entities + persistence modules in the same commit.

### Out of scope
- Matching-engine balance gating (Phase B).
- Backend-v2 `POST /deposit/confirm` + cross-chain deposit confirmation endpoints (Phase C).
- Sweeper-bot (Phase D). Frontend (Phase E). Indexer hardening tests (Phase F).
- Order-book tables (`orders`, failure-path restoration in [recovery.ts:204-241](settlement-engine/src/settlement/database/recovery.ts)) — these are matching-engine concerns, not settled-state; leave as-is until Phase B.

---

## Key files

### settlement-engine (rewrite)
- [index.ts](settlement-engine/src/index.ts) — entry
- [batchProcessor.ts:102-257](settlement-engine/src/settlement/batchProcessor.ts) — poll → process flow
- [processBatch.ts:106](settlement-engine/src/settlement/processBatch.ts) — batch orchestrator
- [smartContract.ts:660-702](settlement-engine/src/settlement/smartContract.ts) — `settleMatches` tx + receipt parsing. **Currently drops `blockHash` and per-log `logIndex`** — must be captured for stamps.
- [database/persistence.ts](settlement-engine/src/settlement/database/persistence.ts) — entire file replaced.
- [database/connection.ts](settlement-engine/src/settlement/database/connection.ts) — keep pool; reuse `withTransaction` only for non-applyOnChainEffect operations (Redis ack coordination).
- [database/recovery.ts](settlement-engine/src/settlement/database/recovery.ts) — `events_processed` retry loop is obsolete once stamps provide idempotency; delete.

### indexer-v3 (reuse + possibly extend)
- `indexer-v3/src/shared/apply-on-chain-effect.ts` — the C10 primitive. Works unchanged.
- `indexer-v3/migrations/004_centuari_positions.sql` — `market`, `lend_position`, `borrow_position` tables. **Confirm `bond_token` columns sufficient for settlement-engine's stamps** before writing; if not, add `005_settlement_stamps.sql`.
- `indexer-v3/src/processors/centuari.processor.ts` — the tail that already handles `MarketCreated`, `LendPositionCreated`, `BorrowPositionCreated`, `Repaid`. Settlement-engine's eager writes must produce rows the tail would then no-op on via `already_stamped` check.
- `indexer-v3/src/processors/balance-ledger.processor.ts` — same pattern for `Credited` / `Debited` (portfolio balance deltas).

### backend-v2 (partial read migration)
- `backend-v2/src/portfolio/` — swap TypeORM queries against legacy `portfolio` / `lend_positions` / `borrow_positions` tables for direct SQL against the shared `user_balance` / `lend_position` / `borrow_position` schema via `DatabaseService`. (Earlier sketch suggested `fetch('http://indexer-v3:42069/portfolio/:user')` — superseded; see A5 note.)
- `backend-v2/src/orders/` — if `orders.settlement_status` is read anywhere downstream for settled state display, redirect that read; otherwise leave `orders` table intact (matching-engine still writes it in Phase B).
- Delete TypeORM entities: `SettlementBatch`, `SettlementItem`, `LendPosition` (backend version), `BorrowPosition` (backend version), `CbtAsset`, `Portfolio`, `Market` (backend version).

---

## Implementation steps

### A1. Capture full receipt metadata in settlement-engine
[smartContract.ts:694-702](settlement-engine/src/settlement/smartContract.ts) — extend `SettlementResult` to include `blockHash: Hex` and preserve `logIndex: number` on every parsed event. Thread through `parseReceiptLogs` so each `ParsedBondToken / ParsedLendPosition / ParsedBorrowPosition` carries its own log index.

### A2. Add the shared helper dep
- Depend on `@centuari-labs/on-chain-effects` (published to GitHub Packages; source lives locally at `on-chain-effects/`). Minimum version **`0.2.0`** — that release adds two optional fields to `applyOnChainEffect`:
  - `receipt?: TransactionReceipt` — skip the helper's internal `waitForTransactionReceipt` when the caller already has the receipt in hand. Settlement-engine's `settleBatch` always returns a mined receipt, so this avoids a redundant RPC call per emitted event.
  - `logIndex?: number` — select a specific log by index (falls back to match-first-by-topic when absent). **Required for settlement-engine** because one `settleMatches(batch)` tx can emit multiple `LendPositionCreated` / `BorrowPositionCreated` logs sharing the same `(marketId, lender|borrower)` key (e.g. one lender partial-filled by two borrowers in the same batch). Without `logIndex`, the helper would apply only the first matching log and silently drop the rest.
- Import `applyOnChainEffect`, `IdempotencyStamp`, `ApplyOnChainEffectResult` from `@centuari-labs/on-chain-effects`.

### A3. Schema audit + (if needed) migration 005
Verify each indexer-v3 table has the columns settlement-engine will stamp:

| Table | Needed data | Gap? |
|---|---|---|
| `user_balance` | Balance deltas for lender (debit principal + fees) + borrower (credit principal − fees) | None. `Credited/Debited` events already covered by [balance-ledger.processor.ts](indexer-v3/src/processors/balance-ledger.processor.ts). Settlement-engine can drive the same upsert. |
| `market` | `(market_id, loan_token, maturity)` | None. Already has stamps. |
| `bond_token` | `(address, asset, maturity, total_supply)` | **Check:** no stamp columns per migration dump. If tail-only, keep as tail-only (immutable after creation) and **do not eager-write** — let the indexer tail own this row exclusively. Confirmed acceptable since bond-token creation is triggered once per market. |
| `lend_position` | `(market_id, lender, bond_token, cbt_balance, principal, rate)` | None in columns. `rate` stored as weighted average — settlement-engine must compute this across the batch per lender per market, same way [persistence.ts:148-165](settlement-engine/src/settlement/database/persistence.ts) does today. |
| `borrow_position` | `(market_id, borrower, principal, debt, rate)` | None. Same rate-rollup logic. |

**Decision:** no new migration needed. Use existing tables as-is. Settlement-engine eager-writes all except `bond_token` (leave to tail).

### A4. Rewrite settlement-engine persistence
Replace [persistence.ts](settlement-engine/src/settlement/database/persistence.ts) with a new module `apply-settlement.ts`. Loop over the **parsed events** returned by `settleBatch()`, not the input matches, so every emitted log gets a dedicated helper call scoped to its own `logIndex`:

```ts
// apply-settlement.ts — one applyOnChainEffect call per parsed event.
// Loop over parsed events (not the input matches) and pass logIndex through
// so a single tx can emit multiple logs for the same (marketId, lender|
// borrower) key and each one gets applied — the ON CONFLICT upsert then
// accumulates principal / cbt_balance correctly.
for (const event of result.lendPositionEvents) {
  await applyOnChainEffect<LendPositionCreatedArgs>({
    client, pool,
    receipt,                      // pre-fetched from settleBatch — no refetch
    txHash: receipt.transactionHash,
    expectedEventTopic: LEND_POSITION_CREATED_TOPIC0,
    logIndex: event.logIndex,     // select the exact log, not first-match
    abi: [LEND_POSITION_CREATED_EVENT],
    expectedArgsPredicate: (a) =>
      a.marketId.toLowerCase() === event.marketId.toLowerCase() &&
      a.lender.toLowerCase()   === event.lender.toLowerCase(),
    alreadyAppliedCheck: (tx, stamp) =>
      alreadyStamped(tx, 'lend_position',
        'market_id = $1 AND lender = $2',
        [hexToBytea(event.marketId), hexToBytea(event.lender)], stamp),
    mutation: (tx, _a, stamp) => tx.query(`INSERT INTO lend_position ...
      ON CONFLICT (market_id, lender) DO UPDATE SET
        cbt_balance = lend_position.cbt_balance + EXCLUDED.cbt_balance,
        principal   = lend_position.principal   + EXCLUDED.principal,
        rate        = EXCLUDED.rate,
        applied_by_* = EXCLUDED.applied_by_*, ...`, [...]),
  });
}
// …same pattern for BorrowPositionCreated.
```

Keep Redis stream ack / nonce management / failure backoff flow in `batchProcessor.ts` unchanged. Only the DB layer is replaced. `processBatch.ts` threads the cached `PublicClient` + `receipt` into `applySettlementResult(pool, client, result)`.

Key differences from current persistence:
- No `settlement_batches` row — the tx hash **is** the batch identity.
- No `settlement_items` join table — matches are identified by `(marketId, lender|borrower, txHash, logIndex)` tuple.
- No separate Phase-1 / Phase-2 split — one atomic `applyOnChainEffect` call per event. If it fails, retry is safe because of stamp idempotency.
- `rate` is **latest-wins** (`EXCLUDED.rate`) per event, mirroring the indexer tail ([centuari.processor.ts](indexer-v3/src/processors/centuari.processor.ts)). No weighted-average rollup — both writers must stay byte-for-byte identical for C10 idempotency.
- Failure-path order restoration in [recovery.ts](settlement-engine/src/settlement/database/recovery.ts) (portfolio unlock + order state update) remains — **that's matching-engine state, not settlement state**; it targets `orders` + `portfolio.locked_amount` which are Phase B concerns.

**Why `logIndex` + `receipt` are both needed (implementation note):** the 0.1.0 helper re-fetched the receipt and picked the first log whose topic0 matched and whose predicate passed. For settlement-engine that would be wrong twice over — (a) the receipt is already in hand, and (b) a batch settlement legitimately emits multiple logs satisfying the same predicate. Version 0.2.0 adds these fields so settlement-engine can opt into explicit log selection.

### A5. Migrate backend-v2 onto the shared on-chain-state schema

**Note (2026-04-23 update):** the earlier sketch of this step suggested a
Fastify-REST client (`http://indexer-v3:42069`) with NestJS cache manager.
That was the wrong abstraction — every Centuari service shares one
Postgres, so backend-v2 queries the canonical tables (`user_balance`,
`lend_position`, `borrow_position`, `market`) directly over its existing
`DatabaseService` pool. Indexer-v3 owns the migrations but the data is a
shared resource; backend-v2 is one of several writers.

Scope expanded beyond the original "reads only" to include eager writes
for endpoints that initiate on-chain txs, because A6 drops the legacy
duplicate tables in the same PR — without the write-side migration,
`POST /portfolio/repay` + `POST /portfolio/withdraw-lend-position` would
silently lose their persistence layer.

**Reads** (portfolio endpoints, backed by the new `OnChainStateRepository`
at `backend-v2/src/core/on-chain-state/`):
- `GET /portfolio/my-portfolio` — balances + lend totals + borrow totals,
  weighted APR from `lend_position.rate × cbt_balance`.
  `allTimeReturn = 0` in A5 (current-state schema does not retain
  `original_shares`; Phase B can reconstruct from match history).
- `GET /portfolio/my-assets` — `user_balance` rows enriched with local
  token metadata + risk params. `lockedInOrders = 0` until Phase B adds
  the matching-engine reservation readout.
- `GET /portfolio/my-health-factor` + `getHealthFactorForAccount` —
  collateral from `user_balance` rows where `used_as_collateral = true`;
  debt aggregated from `borrow_position` per `market.loan_token`.
- `GET /portfolio/my-position` — lend + borrow aggregated per market,
  `marketId` translated bytes32 ↔ UUID via `bytes32ToUuid` to preserve the
  current frontend contract (Phase E will flip to bytes32).
- `GET /portfolio/user-details` — composition of the above.

**Writes** (eager `applyOnChainEffect`, helpers under
`backend-v2/src/core/on-chain-state/apply-*.ts`):
- `POST /portfolio/repay` — `Centuari.repay` → loops `Repaid` + `Debited`
  logs, one `applyOnChainEffect` per parsed event with its own
  `logIndex`. SQL mutations mirror
  [indexer-v3/src/processors/centuari.processor.ts:handleRepaid](../../indexer-v3/src/processors/centuari.processor.ts)
  and
  [balance-ledger.processor.ts:handleBalanceDelta](../../indexer-v3/src/processors/balance-ledger.processor.ts)
  byte-for-byte. Drops the on-chain pre-check + `syncAllPositionsToZero`
  fallback — both obsoleted by stamp idempotency.
- `POST /portfolio/withdraw-lend-position` — same pattern for
  `LendPositionWithdrawn` + `Credited`.

Dependency: bump `@centuari-labs/on-chain-effects` from `^0.1.0` to
`^0.2.0` (adds `receipt` + `logIndex` params — needed to select a specific
log in a multi-event receipt, since a single repay tx can emit both
`Repaid` and `Debited`). Coordinates with A2.

Out of scope for A5 (other phases): `POST /deposit/confirm` +
`ChainIndexerService` (Phase C, depends on the HubDepositor/HubIntentSettler
migration); `POST /withdraw` (Phase C, legacy `Treasury.withdraw` gets
replaced by `WithdrawalRegistry.requestWithdraw`); order/match reads
(chart, history, open orders) — Phase B.

### A6. Delete legacy code in same commit
**Settlement-engine:**
- `src/settlement/database/persistence.ts` — delete.
- `src/settlement/database/recovery.ts` — delete `recoverUnprocessedEvents` + `events_processed` retry; keep only the `orders` failure-path helpers (move to a new `order-failure.ts`).
- `src/settlement/__tests__/database*.test.ts` — delete, replace with tests that mock `applyOnChainEffect`.

**Backend-v2:**
- TypeORM entities: `SettlementBatch`, `SettlementItem`, `LendPosition`, `BorrowPosition`, `CbtAsset`, `Market`, `Portfolio`.
- Their repositories + services.
- Migration file (new) to `DROP TABLE` the legacy tables.

**Docs:**
- Update [phase-1-cross-chain-balance-ledger.md Legacy Deprecation Checklist §Phase A](smart-contract-revamp/docs/phase-1-cross-chain-balance-ledger.md) to mark completed items.

---

## Verification

### Automated
1. `cd smart-contract-revamp && forge test` → 438+ tests green (baseline unchanged).
2. `cd settlement-engine && pnpm test` → rewritten unit tests pass. Key cases:
   - Same batch processed twice → second pass is all `already_stamped` no-ops.
   - Receipt reverted → no DB mutations.
   - Event decoded with mismatched args → `args_mismatch`, no mutation, match gets failure-path treatment.
3. `cd backend-v2 && pnpm test` → portfolio/position read endpoints return indexer-v3-shaped data.

### Manual end-to-end smoke
Preconditions: Docker stack up (`docker-compose up -d`), all contracts deployed via `./bin/run-all.sh`, indexer-v3 running and reporting healthy via `curl localhost:42069/health`.

1. Submit a lend order + matching borrow order through the frontend (or direct REST call to backend-v2).
2. Wait for settlement batch (≤ 5s default interval).
3. `psql $DATABASE_URL -c "SELECT available FROM user_balance WHERE user_address = decode('<lender>', 'hex')"` → lender's `available` decreased by principal + fees.
4. `psql $DATABASE_URL -c "SELECT available FROM user_balance WHERE user_address = decode('<borrower>', 'hex')"` → borrower's `available` increased by principal − fees.
5. `GET /lend-positions/<lender>` via backend-v2 → position row present with correct `cbt_balance` + `principal` + weighted `rate`.
6. Query Postgres: `SELECT applied_by_tx_hash FROM lend_position WHERE lender = $1` → matches the settlement tx hash.
7. **Idempotency:** manually re-run the settlement-engine against the same Redis-stream entries (or replay from a snapshot). No duplicate rows; no position values changed.
8. **Reorg replay** (optional, requires Anvil): force a reorg past the settlement block; confirm `lend_position` rows with `applied_by_block_number > fork_point` are removed and re-applied on replay.

### Observability
- Settlement-engine logs one structured line per `applyOnChainEffect` result: `{ txHash, matchId, eventName, applied: bool, reason?: string }`.
- Alert if `reason === "receipt_reverted"` or `"event_missing"` appears — indicates contract/ABI drift.

---

## Rollback

Rollback is non-trivial because legacy tables are dropped in the same commit. Safe path:
1. Keep the `DROP TABLE` migration in a **separate commit** at the tip of the Phase A PR.
2. If issues surface post-deploy, revert the drop-tables commit only — settlement-engine's new code continues writing indexer-v3 schema; backend-v2 reads continue against indexer-v3. Legacy tables become orphaned but harmless until a clean retry.
3. Full rollback: revert the entire Phase A PR, redeploy.

---

## Risks

- **Rate rollup correctness:** weighted-average `rate` math in `lend_position.upsertRollup` must match what `persistence.ts` does today. Port carefully with unit tests that compare old vs new on the same match set.
- **`bond_token` ownership:** if backend-v2 anywhere writes to `cbt_assets` / `bond_token` outside settlement-engine (e.g. a manual admin script), that path must also migrate. Grep before deleting.
- **Portfolio `locked_amount`:** settlement-engine currently clears `locked_amount` on settle ([persistence.ts:359-371](settlement-engine/src/settlement/database/persistence.ts)). Indexer-v3's `user_balance` has no `locked_amount` — that concept belongs to matching-engine reservations (Phase B's `inOrders`). Confirm frontend doesn't read `locked_amount` for settled state; if it does, coordinate with Phase B.
- **Indexer-v3 tail lag:** backend-v2 reads the shared Postgres directly, so it is independent of indexer-v3 HTTP availability. But indexer-v3 is still the canonical writer for tail-only events (e.g. cross-chain `HubIntentSettler.confirmDeposit`); if the indexer tail lags, those rows stay stale. Surface per-chain tail lag in backend health endpoint via a `SELECT updated_at FROM block_cursor` probe (or proxy `:42069/health`).
