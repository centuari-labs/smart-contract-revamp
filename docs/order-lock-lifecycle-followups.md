# Order Lock Lifecycle — Known Issues + Planned Followups

**Status:** Created 2026-05-10 as part of Phase 1C documentation close-out for the order-lock lifecycle (Phase 1A settlement-engine writeback + Phase 1B backend HF buffer/pending-match counting). Each item below is a known issue or planned improvement that is **not** in Phase 1 scope.

For the shipped Phase 1A + 1B model itself (HF buffer config, lock-increment-on-match, lock-decrement-on-settlement, FILLED-but-unsettled HF gap closure) see the relevant service `CLAUDE.md` files:

- [backend-v2/CLAUDE.md](../../backend-v2/CLAUDE.md) — HF buffer + lock lifecycle + pending-match HF
- [settlement-engine/CLAUDE.md](../../settlement-engine/CLAUDE.md) — settlement writeback contract
- [matching-engine/CLAUDE.md](../../matching-engine/CLAUDE.md) — db-writer match-time lock increment

| # | Item | Status | Bound | Planned fix |
|---|---|---|---|---|
| 1 | Cancel-during-match race window | KNOWN, UNFIXED | UX confusion only — no fund loss | Engine-coordinated cancel (item 2) |
| 2 | Engine-coordinated cancel | NOT STARTED | n/a (closes item 1) | This doc |
| 3 | Stuck `matches.settlement_status='PENDING'` reconciliation | KNOWN, UNFIXED | Inflated `portfolio.locked_amount` until manual fix | 24h sweeper job |

---

## 1. Cancel-during-match race window (KNOWN, UNFIXED)

**Window:** between engine-matches-order and db-writer-flushes-`status=FILLED` (~10ms typical).

**Symptom:** a cancel arriving in that window is silently lost.

**Cause (sequence of events):**

```
T=0       Engine matches order X (in-memory atomic)
T=0       Engine publishes match → Redis Stream
T=0       Engine publishes orders.status=FILLED → NATS
T=??ms    User clicks cancel
          Backend reads orders.status — sees OPEN (db-writer hasn't flushed yet)
          Cancel guard at backend-v2/src/orders/orders.service.ts:286-287 passes
          Backend writes orders.status=CANCELLED
T=??ms+   db-writer's NATS consumer arrives, runs updateOrderStatus
          matching-engine/src/services/db/postgres-db-client.ts:53-72 has no
          WHERE status = ? guard, overwrites with status=FILLED
```

**Net effect:** the order settles normally; the user's cancel button silently failed. UX confusion only — no fund loss because settlement-engine proceeds against the (correctly-matched) order.

**Why not fixed in Phase 1:** the window is bounded (~10ms), the blast radius is UX (not lost funds), and the cleanest fix requires a coordinated backend ↔ engine protocol change (see item 2). Tracked here so future contributors don't re-discover the bug.

**Evidence:**

- Backend cancel guard: [backend-v2/src/orders/orders.service.ts:286-287](../../backend-v2/src/orders/orders.service.ts).
- Db-writer status update with no guard: [matching-engine/src/services/db/postgres-db-client.ts:53-72](../../matching-engine/src/services/db/postgres-db-client.ts).

---

## 2. Planned fix: engine-coordinated cancel

Today, cancel is fire-and-forget: backend updates the DB and publishes `orders.cancel` to NATS; engine handles asynchronously. The proposed change makes cancel a NATS request/reply against the engine so the engine — the only component with the authoritative in-memory book — gets the final say.

**Proposed protocol:**

```
Backend POST /orders/:id/cancel
  → backend NATS request/reply to engine "can-cancel?"
  ↓
Engine looks up order in book:
  - Found in book (still active) → mark as paused (no further matching)
                                 → reply OK
  - Not in book (already matched / fully filled) → reply NACK with reason
                                                   "ALREADY_MATCHED"
  ↓
Backend on OK:   UPDATE orders.status = CANCELLED → publish orders.cancel
Backend on NACK: return 409 Conflict to user
                 "Order already matched, cannot cancel"
Engine on OK reply: remove the paused order from book
```

**Trade-offs:**

- **Pro:** race window eliminated; backend never writes `CANCELLED` for an already-matched order.
- **Pro:** clear UX — user sees "already matched" instead of silent failure.
- **Con:** cancel becomes synchronous (~5-20ms NATS round-trip).
- **Con:** engine must implement pause-state for in-flight cancel checks.

**Out of scope for Phase 1** because it isn't blocking lock-release correctness. Worthwhile follow-up phase but no firm date.

---

## 3. Stuck `matches.settlement_status='PENDING'` reconciliation (KNOWN, UNFIXED)

If settlement never lands for a match — settlement-engine crash mid-batch, on-chain revert that doesn't get retried, RPC outage that exhausts retries — the `matches` row is stuck `settlement_status='PENDING'` and the lender + borrower's `portfolio.locked_amount` stays inflated forever. The user's available balance remains under-counted by the locked amount until a human intervenes.

**Mitigation today:** none. Settlement-engine retries are best-effort; there is no separate watchdog for stuck rows.

**Planned fix:** a separate reconciliation job that periodically sweeps:

```sql
SELECT id, lender_account_id, borrower_account_id, asset_id, created_at
FROM matches
WHERE settlement_status = 'PENDING'
  AND created_at < NOW() - INTERVAL '24 hours';
```

For each row, the job alerts (on-call paging) and either retries the on-chain settlement (if the underlying issue is transient) or marks the match `FAILED` and releases the locks (if the on-chain side is unrecoverable).

**Out of scope for Phase 1.** No firm date.

---

## Out of scope for this followups doc

- **Code-comment cleanups** — e.g., the `lock-release.ts` header-comment-vs-actual-structure inconsistency (the comment says "extends the existing applyOnChainEffect mutation closure" but the actual call structure runs the writeback alongside, not inside, that closure). These are small spawn_task / inline-fix items, not lifecycle follow-ups.
- **Phase 6 on-chain direct order placement** — handled by the smart-contract Phase 6 plan, not the order-lock lifecycle.
