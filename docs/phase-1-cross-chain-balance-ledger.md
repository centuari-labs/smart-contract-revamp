# Centuari Phase 1 — Cross-Chain + BalanceLedger Implementation Plan

## Context

Centuari is migrating from a single-chain, deposit-at-order-time lending protocol (current staging) to a cross-chain, deposit-first, gasless-orders protocol. This plan covers **Phase 1 only** from the Centuari Full Architecture v6 document and `Centuari_Implementation_Plan.pdf`.

**What Phase 1 delivers:** a user can deposit USDC on Base (or any spoke chain), have balance credited on Arbitrum within ~3 seconds via a solver-fronted cross-chain flow, lend/borrow against that balance (existing flows), then withdraw back to any supported chain. All tracked through a new `BalanceLedger.sol` with 3 sub-states (`available`, `inOrders`, `inYieldRouter`) plus a per-(user, asset) **on-chain** `usedAsCollateral` flag, auto-set at borrow-match settlement, auto-cleared on full repay, and otherwise lockable for a minimum 24 hours through a new `CollateralManager.sol` wrapper contract — with every unflag and every withdrawal gated by a single `IRiskModule` seam (stub in Phase 1, real HF math in Phase 2).

**Why this first:** every later phase (Risk/Liquidation, Settlement Upgrade, Maturity Engine, Gasless, DeFi Integration) depends on BalanceLedger's sub-state model. BalanceLedger + cross-chain is the foundation.

**Collateral model — HF-gated, no physical lockup, on-chain flag.** Centuari does NOT lock collateral into a separate balance bucket when a user borrows. Instead, collateral is "virtual": the user flags assets they're willing to use as collateral, and the (Phase 2) RiskModule continuously computes a health factor from the user's `available` balances across all flagged assets against their outstanding debt. Any user-initiated outflow (withdrawal, cross-asset transfer, yield routing) is gated by "post-action HF >= 1". This matches Aave/Compound/Morpho, is strictly more capital-efficient than physical lockup, composes cleanly with Phase 6 on-chain integrators (they only read `available` + HF, not a zoo of lock-sub-states), and avoids per-borrow allocation bookkeeping entirely. **The flag lives on-chain** on `BalanceLedger`, but users never sign or pay gas to set it — flagging is an automatic side effect of the protocol-signed settlement tx that records a borrow match, and unflagging on full repay is an automatic side effect of the protocol-signed repay tx. Mid-life unflagging (while still in debt) goes through a small `CollateralManager.sol` wrapper with a 24-hour flag-lock and a `RiskModule` gate. Phase 1 ships a conservative `RiskModuleStub` (rejects any unflag while debt > 0); Phase 2 swaps in the real oracle-backed `RiskModule` via a single governance call. This design closes the loophole where a user with off-chain collateral state could bypass the backend and call `WithdrawalRegistry` directly to exit with borrowed funds — see Module 1's "Why the flag is on-chain" section and the `CollateralManager` spec below.

**Reference, not gospel:** the branch `feat/centuari-full-implementation` in `smart-contract-revamp/` already contains first-pass versions of `BalanceLedger.sol`, `HubIntentSettler.sol`, `SettlementLedger.sol`, `WithdrawalRegistry.sol`, `SpokeVaultStable.sol`, `SpokePayout.sol` (per exploration). These are cited as "confusing / prone to bug" by the user and are to be treated as reference sketches, not starting points. `SpokeDepositGateway.sol` is missing entirely from that branch. The cross-chain wiring lives on a separate commit (`95dc1c7`) that has not been brought into staging. Off-chain service updates (`backend-v2`, `frontend-revamp`, `settlement-engine`, `matching-engine`, `indexer-v2`) are NOT present on the feat branch — those must be built as part of Phase 1D.

---

## Architectural Concerns (Challenges to the Full Architecture Doc)

Before implementing, the following issues in the architecture must be resolved or explicitly acknowledged. Each one will show up as a concrete decision point during implementation.

### C1. One-click gasless + signatureless UX (perp-DEX style)

User requirement: placing, cancelling, and replacing orders must be single-button — no signing, no gas, no waiting on a wallet popup. Same feel as Hyperliquid / dYdX v4 / Lighter.

This is already achievable with the existing Centuari stack — the current staging build routes orders through the backend (Privy JWT auth) to the matching engine over NATS, with zero per-order on-chain signatures. What Phase 1 changes is WHERE the matching engine gets its balance view (indexer-v2 instead of backend state) and WHERE settlement debits come from (BalanceLedger instead of Treasury). **The order-placement UX does not change: user Privy-auths once per session, every subsequent order is one click.**

**Phase 1 order flow (all off-chain, zero user signatures after Privy session auth):**

1. User opens the app → Privy session established → backend issues session JWT.
2. User clicks "Lend 100 USDC at 8% / 30d" → frontend POSTs `{market, side, price, amount}` to backend with JWT → zero wallet prompts.
3. Backend validates JWT, forwards order to matching engine via NATS.
4. Matching engine reads `BalanceLedger.available(user, asset)` from indexer-v2 (sub-ms lookup on same docker network), subtracts its own per-user Redis reservation counter, accepts the order if `available - reservation >= orderAmount`, and increments the reservation.
5. Cancel / replace are NATS messages — also zero signatures, zero tx, zero gas.
6. On a match, the settlement engine batches matches and submits the batch on-chain with the PROTOCOL's settlement key (unchanged from today). The on-chain debit against `BalanceLedger.available` is authorized by the protocol's settlement role, not by user signatures. Users never see a wallet popup for order flow.

Trust model: same as perp DEXes and today's Centuari — users trust the sequencer/matching engine to honour their orders, but CANNOT be rugged because (a) deposits/withdrawals still require on-chain custody transitions that the sequencer cannot unilaterally forge, and (b) exit is always permissionless via `WithdrawalRegistry`.

**Consequence for BalanceLedger design:** since no off-chain order placement ever writes to BalanceLedger, the `inOrders` sub-state is NOT used by the Phase 1 order flow. It exists only as a forward-compat slot for Phase 6's `CentuariRouter` (the on-chain integration path for external DeFi protocols — those integrators will write to `inOrders` so their on-chain callers can see locked commitments). **Phase 1 BalanceLedger writes `available` (via credit/debit) and the `usedAsCollateral` flag (via `markCollateral`/`unmarkCollateral`) during settlement and repay.** There is no `collateral` balance sub-state at all — collateral is virtual, gated by the Phase 2 RiskModule's HF math applied on top of the on-chain flag. The flag is written exclusively by authorized-writer contracts (`Settlement`, `Centuari`, and the new `CollateralManager`); there is no user-callable toggle endpoint, which is how the gas-spam vector is eliminated by construction. `inOrders` and `inYieldRouter` live in storage for layout stability but have zero entry points in Phase 1.

**Risk of the off-chain reservation model:** if engine Redis state and on-chain state diverge (e.g., engine crashes and replays old orders), the engine could construct a settlement batch that exceeds `available`. Mitigation: the settlement path re-reads `available` for every debited user in the batch and reverts the whole batch atomically if any debit would underflow. The engine then drops the bad order and resubmits. Matches §2.9 of the architecture.

### C2. Phase 1 doesn't build CentuariEndpoint (that's Phase 3)

The Phase 1A spec says "Update Centuari.sol — Replace Treasury calls with BalanceLedger calls." Phase 3A then builds `CentuariEndpoint.sol` to supersede the current `Settlement.sol`. This means Phase 1's Centuari.sol is the authorized writer to BalanceLedger until Phase 3 adds CentuariEndpoint to the writer list via the 48h timelock. That's fine, but the BalanceLedger writer-registration mechanism must support **add/remove over time** without a contract upgrade — and the initial set must be small to keep blast radius low.

**Resolution:** BalanceLedger starts with a single authorized writer (Centuari.sol) + a governance role that can add/remove writers under a 48h timelock. YieldRouter, WithdrawalRegistry, CentuariEndpoint, and LiquidationEngine are added later via governance.

### C3. Matching engine currently doesn't read on-chain balance at all

Per exploration, the matching engine has no on-chain balance checks today; it trusts the backend. For Phase 1, it needs to read `BalanceLedger.available(user, asset)` before accepting an order (Full Architecture §2.3 Step 2). This is a new RPC integration on the hot path — latency matters.

**Resolution:** the engine reads from **indexer-v2** (Module 8), not directly from chain RPC. The custom indexer maintains an always-current snapshot of `UserBalance` entities via event subscription; the engine queries the indexer's REST/internal API for `available`. Indexer is colocated with the engine (same Docker network) so latency is sub-ms. If the indexer is down, the engine falls back to a direct RPC read cached per block. Reservation tracking (Redis) subtracts from the snapshot. Full consistency is still enforced at settlement, not at order placement.

### C4. Solver capital commitment is large and not free

Full Architecture §2.7: solver must hold "20% of peak 24h deposit volume per spoke" as hub-side Arbitrum balance. For 5 spokes and any non-trivial volume this is meaningful capital. Phase 1D's "Solver Service (new)" description buries this. It is an operational cost, not just a service to run.

**Resolution:** in Phase 1D, document the solver's funding requirement explicitly, start with a minimum hard-coded cap (e.g., $50k per spoke for testnet), and build the solver so the cap is a config value. Include a dashboard alert for solver balance < 2x peak fill amount.

### C5. Cross-chain deposit: no user-signed intents; the on-chain deposit IS the intent

User requirement (extended from C1): cross-chain deposits must also be low-signature. User should NOT sign any EIP-712 `GaslessCrossChainOrder`. The only signature the user ever produces for a cross-chain deposit is the on-chain tx that locks their own tokens on the spoke — unavoidable because funds originate in their wallet.

**Revised flow (no ERC-7683 user signatures):**

1. User clicks "Deposit 100 USDC from Base" in the frontend.
2. Wallet opens. User confirms ONE tx: `SpokeDepositGateway.deposit(asset, amount, hubRecipient)` on Base Sepolia. If the token supports EIP-2612, this is a single `permitAndDeposit` call (no prior approve). Otherwise it's approve + deposit (two clicks — same as the current staging UX). The user pays gas on Base (cheap).
3. `SpokeDepositGateway` pulls the tokens into its escrow and emits `DepositInitiated(depositId, user, asset, amount, hubRecipient)`. `depositId = keccak256(chainId, tx.origin, nonce)`. **This event is the intent.** No off-chain signing at all.
4. Solver service watches `DepositInitiated` events on all 4 spokes. On seeing one, it calls `HubIntentSettler.fillFor(depositId, user, asset, amount, sourceChainId, proof)` on Arbitrum using its own hub-side USDC. The `proof` is a LayerZero message carrying the spoke event (so the hub contract cannot be spoofed — see below).
5. `HubIntentSettler` verifies the LZ message came from the correct `SpokeDepositGateway` on the correct chain, credits `BalanceLedger.available[user] += amount`, and registers a solver reimbursement obligation with `SettlementLedger`.
6. User's balance appears on Arbitrum in ~3s (time from spoke tx confirmation + LZ latency for the cheap-message proof). Solver is later reimbursed when the Sweeper bridges the escrowed USDC from spoke → hub via CCTP/OFT (5–20 min).

**Refund race resolution:**

- If the solver never fills (offline, out of capital, timeout), `SpokeDepositGateway` lets the user reclaim their escrow via `refund(depositId)`, gated on a LayerZero message from hub attesting "no fill recorded for this depositId within N minutes". Same pattern as before, but the message carries the `depositId` rather than an intent hash. A keeper (Phase 1: Centuari-operated, same process as the Solver service) fires the proof-of-non-fill messages after the timeout window expires.
- Double-credit is impossible because `SpokeDepositGateway.refund()` requires the LZ proof-of-non-fill, and the hub will only issue that proof if `HubIntentSettler` has no record of the `depositId`. If the solver fills, the hub records the depositId and the proof-of-non-fill is never issued.

**Impact on module structure:**

- `SpokeDepositGateway` in the original plan is renamed to `SpokeDepositGateway` and built from scratch (still absent from the feat branch).
- `HubIntentSettler.fillFor` no longer takes an EIP-712-signed `GaslessCrossChainOrder`. It takes a `depositId` + LayerZero proof of the spoke event.
- Frontend deposit hook does NOT call `signTypedData`. It calls `useWriteContract` against `SpokeDepositGateway.permitAndDeposit` (or plain `deposit`).
- Backend does NOT construct or forward signed intents. It may optionally surface the pending deposit state to the frontend by polling indexer-v2, but the user's wallet drives the deposit directly.

### C6. indexer-v2 must be built from scratch in Phase 1 (custom, not Ponder)

The docker-compose file references `indexer-v2/` but the directory does not exist in the repo. Phase 1D assumes it can "update event schemas" but there is no indexer to update.

**Prior consideration — Ponder rejected:** Ponder forces a framework-shaped schema and handler model that did not fit the Centuari architecture on the previous attempt. Ponder's strict event-driven handler pattern and internal schema abstraction got in the way of tracking multi-chain state rollups (e.g., a single user's balance reflects events from both the hub and the spoke `SpokeDepositGateway`). Dropped.

**Resolution:** Phase 1 Module 8 builds a **custom Node.js/TypeScript indexer** using Viem's `watchEvent` + `getLogs` with a Postgres backend and a fully user-controlled schema. No framework lock-in. Same stack conventions as backend-v2 (TypeScript, pnpm, Viem, raw `pg` for Postgres, Biome for lint). Phase 1 scope is minimal: index `BalanceLedger`, `Centuari`, `HubIntentSettler`, `WithdrawalRegistry`, `SettlementLedger` on the hub, and `SpokeVaultStable`, `SpokeDepositGateway` on each of the four spokes. Expose a small REST API (Fastify or Hono) for backend/frontend/matching-engine consumption.

### C7. LayerZero DVN configuration is security-critical and easy to get wrong

§8.11 of the architecture explicitly warns that the default DVN config is a placeholder. Phase 1C needs to set DVN stacks per pathway BEFORE going live. The implementation plan mentions "2-of-3 standard, 3-of-3 liquidation" but doesn't specify the DVN providers. For testnet we can pick any two, but the DVN selection is a pre-mainnet decision point.

**Resolution:** Phase 1C picks two testnet DVNs (LayerZero Labs DVN + Google Cloud DVN or similar), configures 2-of-2 on both directions for testnet, and files the 3-of-3 liquidation pathway as a Phase 2 follow-up (liquidation engine doesn't exist in Phase 1 anyway).

### C8. Existing users / testnet migration

There are likely balances already in Treasury on the Arbitrum Sepolia testnet. Phase 1A says "All existing flows must work identically" but does not state a migration path.

**Resolution:** testnet only — redeploy cleanly, accept that existing testnet balances are wiped. Document this as a known cutover. For mainnet (later), a separate migration plan will be required.

### C9. Arbitrum is the hub — no spoke deployment needed on Arbitrum itself

When a user deposits USDC while on Arbitrum, they are already on the hub chain. There is no solver, no bridge, no LayerZero message. The user simply approves + calls a direct-deposit function on Arbitrum that pulls the token and credits `BalanceLedger.available` in the same transaction.

**Resolution:** spoke contracts (`SpokeVaultStable`, `SpokePayout`, `SpokeDepositGateway`) deploy to the 4 spoke chains only (Base, Ethereum, BNB, Polygon). Arbitrum gets a thin `HubDepositor.sol` contract (or the equivalent function lives directly on `Centuari.sol`) that is the single direct-deposit entry point for hub-native deposits. Withdrawals that target Arbitrum are handled similarly: `WithdrawalRegistry` authorizes, then a hub-side `HubPayout` helper releases tokens on Arbitrum directly. No LZ message for hub-native withdrawals.

The frontend's target-chain selector includes "Arbitrum (direct)" as an option distinct from the four spokes.

### C10. Eager DB sync after on-chain calls; indexer-v2 is the safety net, not the fast path

Indexer-v2 tails chain events and is eventually consistent with chain state, but its latency is non-zero (a few hundred ms at best, multiple seconds under load) and it is a separate process that can lag, crash, or be restarted. If every UI read depended on the indexer having already tailed the tx that just landed, the UX would feel slow and inconsistent, and reconciliation bugs would look like "my balance disappeared".

**Resolution — two-writer pattern for every on-chain mutation:**

For every tx that mutates DB-visible state (deposit, settlement, withdrawal authorization, solver fill, sweeper bridge, etc.), the **service that submitted the tx** is also responsible for **eagerly writing the resulting DB mutation as soon as the tx receipt lands and is verified**. The indexer tails the same event in parallel as a **safety net** — if the eager path fails (service crash mid-verification, network blip, receipt fetch timeout, a reorg that replaces the tx), the indexer backfills from the chain event and the DB converges.

**The pattern:**

1. Service submits tx with Viem, awaits receipt.
2. Service verifies the receipt: `status == success`, expected event logs present, event args match what the service intended to do.
3. If verification passes, service applies the mutation directly to the shared Postgres DB inside a transaction that **also stamps the row with `applied_by_tx_hash` and `applied_by_log_index`**. This stamp is what makes the eager path idempotent with the indexer path.
4. If verification fails (receipt status reverted, wrong event, mismatched args), the service does NOT apply anything — the indexer will either (a) converge later if the tx silently succeeded, or (b) never apply anything if the tx genuinely reverted.
5. The indexer processor for that event type checks `applied_by_tx_hash` before writing: if it's already set to the same tx hash, the indexer skips (no-op). If it's unset or set to a different tx, the indexer applies its mutation. Both writers converge to the same row state.

**Reorg handling stays unchanged:** the indexer's reorg detector compares block hashes on every new head and removes any rows whose `block_hash` was replaced, then replays from the fork point. The eager path stamps `block_hash` + `block_number` alongside `applied_by_tx_hash`, so a reorg-evicted row is cleaned up the same way regardless of which writer created it.

**Consequence for module design:**

- **Settlement engine (Module 9)** updates `user_balance.available` immediately after each successful batch submission; indexer tails `BalanceLedger.Credited/Debited` as backup.
- **Solver service (Module 6)** updates `intent_order.state = FILLED` and `user_balance.available += amount` for the credited user immediately after its `HubIntentSettler.fillFor` tx lands; indexer tails `SolverFillRegistered` as backup.
- **Sweeper bot (Module 7)** updates `intent_order.state = SETTLED` and `solver_reimbursement.state = REIMBURSED` immediately after its bridge + `SettlementLedger.match` txs land; indexer tails as backup.
- **Backend deposit module (Module 9)** — when the frontend POSTs a deposit tx hash, the backend fetches the receipt, verifies the `HubDepositor.Deposited` or `SpokeDepositGateway.DepositInitiated` event, and eagerly applies the row update; indexer tails as backup.
- **WithdrawalRegistry state transitions (Module 9)** — backend updates `withdrawal_request.state` on each authorize / complete / fail tx; indexer tails as backup.
- **Frontend (Module 10)** always reads from the same DB (via backend or indexer REST — they return the same rows). Because the eager path is usually faster than the indexer, the user sees updated state within a few hundred ms of the tx landing, not seconds later.

**What lives on the shared library vs. per-service:**

The verify-then-apply pattern is a small shared helper in `indexer-v2/src/shared/apply-on-chain-effect.ts` (exported for re-use) that takes `(txHash, expectedEventSelector, expectedArgs, mutationFn)` and handles receipt fetch, log parsing, idempotency stamping, and transactional commit. Both the indexer processors and the eager-path services import it so there is exactly one place where the idempotency invariant is enforced.

**Note on the collateral flag (now on-chain):**

The `usedAsCollateral` flag is on-chain in Phase 1 and is written by one of three paths: (a) auto-flag inside `Settlement.settle()` at borrow match settlement, (b) auto-unflag inside `Centuari.repay()` when debt hits zero, (c) mid-life unflag through `CollateralManager.unflagFor()` gated by the 24h flag-lock + `RiskModule.canUnflag`. All three emit `BalanceLedger.CollateralFlagSet(user, asset, used, flaggedAt)` which indexer-v2 tails into the `user_balance.used_as_collateral` column with the same C10 idempotency stamps as every other event. Whichever service submitted the underlying tx (settlement-engine for settle, backend-v2 for repay and unflag) eagerly applies the mutation via `applyOnChainEffect` so the UI reflects the flag change within a few hundred ms rather than waiting on the indexer tail.

---

## Module Breakdown

Phase 1 is broken into **10 modules**. Each module is independently reviewable, compiles/tests in isolation, and has its own verification checklist. Modules are grouped into the four sub-phases from the implementation plan (1A / 1B / 1C / 1D).

**Status legend:** each module is marked with one of:
- 🟢 **DONE** — code merged, tests passing, verification checklist complete
- 🟡 **IN PROGRESS** — actively being implemented
- ⚪ **NOT STARTED** — dependencies not yet met or not yet scheduled

**Current Phase 1 status (as of 2026-04-09):**

| Module | Status | Notes |
|---|---|---|
| M1 — BalanceLedger.sol core | 🟡 **IN PROGRESS** | 3-state model landed 2026-04-09 with 31/31 tests. Rolled back from DONE to add **on-chain `usedAsCollateral` mapping + `_flaggedAt` stamp + `_flaggedAssets` set + `markCollateral`/`unmarkCollateral` + new `CollateralFlagSet` event**. Storage gap shrinks 45→42 to cover the three new slots. Testnet redeploy, not a real upgrade (C8). |
| M1b — IRiskModule + RiskModuleStub + CollateralManager | ⚪ NOT STARTED | New contracts landing alongside M1's extension. `CollateralManager` holds the 24h flag-lock + `RiskModule.canUnflag` gate for mid-life unflags. Stub returns `canUnflag = (debt == 0)`; Phase 2 swaps the pointer for real HF math. |
| M2 — Centuari.sol migration off Treasury | ⚪ NOT STARTED | unblocked by M1 |
| M3 — Deployment scripts + testnet cutover + HubDepositor | ⚪ NOT STARTED | blocked on M2 |
| M4 — WithdrawalRegistry + HubIntentSettler + SettlementLedger | ⚪ NOT STARTED | blocked on M3 |
| M5 — Spoke contracts + LayerZero DVN wiring | ⚪ NOT STARTED | blocked on M4 |
| M6 — Solver Service | ⚪ NOT STARTED | blocked on M5 |
| M7 — Sweeper Bot | ⚪ NOT STARTED | blocked on M6 |
| M8 — indexer-v2 from scratch | ⚪ NOT STARTED | can start in parallel with M4 after M3 |
| M9 — backend-v2 + settlement-engine + matching-engine updates | ⚪ NOT STARTED | blocked on M8 |
| M10 — frontend-revamp cross-chain UI + collateral toggle | ⚪ NOT STARTED | blocked on M4/M5 + M9 |

Dependency chain (no module starts until its deps are merged + verified):

```
M1 (BalanceLedger core)
 └─ M2 (Centuari.sol migration)
     └─ M3 (Deploy scripts + testnet redeploy)
         ├─ M4 (WithdrawalRegistry + Hub cross-chain contracts)
         │   └─ M5 (SpokeDepositGateway + Spoke contracts + LayerZero wiring)
         │       └─ M6 (Solver Service)
         │           └─ M7 (Sweeper Bot)
         ├─ M8 (indexer-v2 from scratch)
         │   └─ M9 (backend-v2 + settlement-engine + matching-engine updates)
         │       └─ M10 (frontend-revamp cross-chain UI)
```

After M3 is merged, M4 and M8 can be worked on in parallel (different trees). M9 depends on M8 being live with event schemas. M10 depends on M4/M5 (to know the deposit intent shape) and M9 (to know the API shape).

---

## Phase 1A — BalanceLedger + Centuari Migration

### Module 1: BalanceLedger.sol core 🟡 IN PROGRESS

**History:** the 3-balance-state portion landed 2026-04-09 with 31/31 tests passing (`available` / `inOrders` / `inYieldRouter`, gap `uint256[45]`). This module then **rolled back from DONE to IN PROGRESS** to add an on-chain `usedAsCollateral` flag with a per-(user, asset) timestamp and a flagged-asset set. The rollback was triggered by a design review that identified an exit-loophole: `WithdrawalRegistry` is deliberately on-chain and permissionless (a load-bearing trust property — doc C1), but an off-chain flag cannot be read inside an on-chain withdrawal call, so any user (app or Phase 6 integrator) could bypass the backend and withdraw flagged collateral while holding debt. Moving the flag on-chain closes the loophole with a single uniform HF gate for every caller.

**Scope:** extend the existing `BalanceLedger` to store the collateral flag, the flag timestamp (for the 24-hour flag-lock), and a per-user enumerable set of flagged assets. Keep the contract a dumb accounting substrate — **all policy (HF gate, 24h flag-lock, role checks) lives in the writer-side wrappers `CollateralManager` / `WithdrawalRegistry`, never in BalanceLedger itself.** Integrators (Phase 6 `CentuariRouter`) can either compose with `CollateralManager` or bring their own policy on top of the same storage.

**Addresses concerns:** C1 (on-chain flag still preserves zero-signature UX because all flag writes are protocol-signed side effects of already-gas-paid operations), C2 (writer registration with timelock — `CollateralManager` is added to the writer list via the standard 48h governance path).

**Files to create/modify:**

- `smart-contract-revamp/src/core/balance-ledger/BalanceLedger.sol` — add `markCollateral` / `unmarkCollateral` / `usedAsCollateral` / `flaggedAssetsOf` / `flaggedAt` + `CollateralFlagSet` event.
- `smart-contract-revamp/src/core/balance-ledger/BalanceLedgerStorage.sol` — add three mappings (see below); shrink gap `uint256[45]` → `uint256[42]`.
- `smart-contract-revamp/src/interfaces/IBalanceLedger.sol` — reflect the new functions + event.
- `smart-contract-revamp/test/balance-ledger/BalanceLedger.t.sol` — new tests for mark/unmark semantics, idempotency (repeated mark must not refresh the flag timestamp), writer-gating, and storage layout snapshot refresh.

**New storage (in `BalanceLedgerStorage`):**

```solidity
// New collateral-related storage (Phase 1 extension)
mapping(address user => mapping(address asset => bool)) internal _usedAsCollateral;
mapping(address user => EnumerableSet.AddressSet) internal _flaggedAssets;
mapping(address user => mapping(address asset => uint64)) internal _flaggedAt;

// Gap shrinks from 45 to 42 to account for the three new slots.
uint256[42] private __gap;
```

`EnumerableSet` is OpenZeppelin's standard; it is already available because the existing codebase uses it elsewhere.

**Key functions (collateral surface — all writer-gated, none user-callable):**

- `markCollateral(address user, address asset)` — if currently `false`, sets `_usedAsCollateral[user][asset] = true`, adds `asset` to `_flaggedAssets[user]`, stamps `_flaggedAt[user][asset] = uint64(block.timestamp)`, emits `CollateralFlagSet(user, asset, true, flaggedAt)`. **If already `true`, no-op** — importantly, this does NOT refresh `_flaggedAt`, so repeated flagging across multiple borrow matches does not extend the 24-hour lock beyond the first flag.
- `unmarkCollateral(address user, address asset)` — idempotent; sets flag false, removes from set, clears `_flaggedAt`, emits `CollateralFlagSet(user, asset, false, 0)`. **Does not enforce the 24h flag-lock itself** — that check lives in `CollateralManager`. This is intentional: the `Centuari.repay()` auto-unflag path must be able to clear flags atomically with a full repayment regardless of when the flag was set, so it calls `unmarkCollateral` directly (bypassing the flag-lock). `CollateralManager` layers the flag-lock on top of this primitive for the mid-life-unflag path.
- Views: `usedAsCollateral(user, asset) -> bool`, `flaggedAssetsOf(user) -> address[]` (full enumeration; used by `Centuari.repay`'s auto-clear loop and by off-chain HF jobs), `flaggedAt(user, asset) -> uint64`.

**Existing balance functions (unchanged from the 2026-04-09 landing):**

- `credit(user, asset, amount)` / `debit(user, asset, amount)` — unchanged.
- `inOrders` / `inYieldRouter` — still read-only in Phase 1; Phase 5B / 6 wire the entry points.
- Writer management + pause — unchanged.

**Event:**

```solidity
event CollateralFlagSet(
    address indexed user,
    address indexed asset,
    bool used,
    uint64 flaggedAt    // 0 when used == false
);
```

Indexer-v2 listens for this event and writes `user_balance.used_as_collateral` + `user_balance.flagged_at` with the C10 idempotency stamps.

**What is explicitly NOT in BalanceLedger (deliberate exclusions):**

- No `moveToCollateral` / `moveFromCollateral` — borrowing does not lock balance; the (Phase 2) RiskModule constrains user-initiated outflows via HF math on top of the flag + balances. Aave/Compound pattern.
- No physical `collateral` storage field. The struct still has exactly three `uint256` sub-balances.
- **No HF check inside BalanceLedger.** HF gating lives in `CollateralManager` and `WithdrawalRegistry`, which both call `IRiskModule.canUnflag` / `canWithdraw` through the same interface. This keeps BalanceLedger decoupled from the Phase 2 RiskModule ABI; the Phase 2 swap is a single `CollateralManager.setRiskModule(addr)` governance call with zero changes to BalanceLedger.
- **No user-callable toggle.** Users never call `markCollateral` / `unmarkCollateral` directly — the writer allowlist rejects them. Flag writes come from three, and only three, places: `Settlement.settle()` auto-flag at borrow match, `Centuari.repay()` auto-unflag on debt-clear, and `CollateralManager.unflagFor()` for the mid-life unflag path.

**Why the flag is on-chain (replacing the old "Why the flag is off-chain" section):**

1. **The loophole is fatal and unavoidable off-chain.** Any on-chain permissionless withdrawal path cannot read an off-chain flag. `WithdrawalRegistry` must be permissionless (that's the anti-censorship guarantee that lets users trust the sequencer). Therefore the flag must be on-chain for the HF gate to apply uniformly. No amount of backend bookkeeping can fix it.
2. **The spam vector the old design feared is eliminated by construction, not by rate-limiting.** The old design worried that a user-callable on-chain toggle would let users drain the protocol settlement key's gas budget. The new design removes the user-callable toggle entirely. There are three write paths: `Settlement.settle()` (amortized into settlement gas, which the protocol already pays), `Centuari.repay()` (amortized into repay gas, same), and `CollateralManager.unflagFor()` (24h flag-lock limits it to 1 unflag per asset per day per user + 5/user/24h backend rate limit). An attacker who wants to spam 1000 unflags needs 1000 distinct flagged assets AND 1000 prior borrow matches — not economically viable on any network.
3. **Zero user signatures preserved.** None of the three write paths require a user signature. The user signs deposits; everything else is protocol-signed.

**Initial authorized writers (Phase 1):** `Centuari.sol`, `HubDepositor.sol` (M3), and `CollateralManager.sol` (M1b). `Settlement.sol` is already on the writer list per M2. Phase 6 adds `CentuariRouter` via the 48h timelock.

**Testing requirements:**

- Unit tests for every new state transition (`markCollateral` / `unmarkCollateral`) including: idempotency, non-refresh of `_flaggedAt` on repeat mark, set membership sync, event emission, writer-only access.
- Fuzz test: random sequences of (mark/unmark, credit/debit) maintain the invariant `usedAsCollateral(u, a) <=> a ∈ flaggedAssetsOf(u)`.
- Access control: unauthorized caller reverts on every mutator (including the new ones).
- Existing tests (31/31) must still pass after the extension.
- Upgrade safety: `forge inspect BalanceLedger storageLayout` snapshot refreshed and committed; total slot count preserved (three new slots + gap shrunk from 45 to 42 = same total).

**Verification:**

- `forge test --match-contract BalanceLedger -vv` reports the original 31 tests plus the new collateral-surface tests all green.
- `forge inspect BalanceLedger storageLayout` matches the refreshed committed snapshot and slot count is unchanged from the pre-extension layout.
- 100% line coverage on the new mark/unmark paths.

---

### Module 1b: IRiskModule + RiskModuleStub + CollateralManager ⚪ NOT STARTED

**Scope:** three new small contracts that sit between `BalanceLedger` and all the unflag / withdrawal entry points. They concentrate all policy (HF gate, 24h flag-lock, role checks) so that `BalanceLedger` stays a dumb accounting substrate and the Phase 2 RiskModule swap is a single governance call with zero changes anywhere else.

**Addresses concerns:** C1 (all flag writes remain protocol-signed, zero user signatures), and the loophole fix from the design-review rollback of M1.

**Files to create:**

- `smart-contract-revamp/src/interfaces/IRiskModule.sol`
- `smart-contract-revamp/src/core/risk/RiskModuleStub.sol`
- `smart-contract-revamp/src/core/collateral/CollateralManager.sol`
- `smart-contract-revamp/src/core/collateral/CollateralManagerStorage.sol` (separate storage contract for upgrade safety, same pattern as the rest of the codebase)
- `smart-contract-revamp/src/interfaces/ICollateralManager.sol`
- `smart-contract-revamp/test/risk/RiskModuleStub.t.sol`
- `smart-contract-revamp/test/collateral/CollateralManager.t.sol`

**`IRiskModule` interface:**

```solidity
interface IRiskModule {
    /// @notice Returns true iff unflagging `asset` for `user` would keep the user healthy.
    ///         Phase 1 stub returns (centuari.totalDebt(user) == 0).
    ///         Phase 2 real returns HF(user, with asset unflagged) >= 1.
    function canUnflag(address user, address asset) external view returns (bool);

    /// @notice Returns true iff withdrawing `amount` of `asset` for `user` would keep the user healthy.
    ///         Phase 1 stub returns (!usedAsCollateral(user, asset) || totalDebt(user) == 0).
    ///         Phase 2 real returns post-withdrawal HF(user) >= 1.
    function canWithdraw(address user, address asset, uint256 amount) external view returns (bool);
}
```

**`RiskModuleStub` (Phase 1):** reads only `BalanceLedger.usedAsCollateral` + `Centuari.totalDebt`. No oracle, no prices. Fail-closed: if the user has any debt and the action touches a flagged asset, reject. Phase 2 replaces this file with `RiskModule.sol` backed by an oracle and real HF math; `CollateralManager.setRiskModule(newAddr)` via the 48h timelock flips the pointer — no other code changes.

**`CollateralManager` (Phase 1):**

- Upgradeable (ERC1967), same pattern as `Centuari` / `Settlement` / `BalanceLedger`.
- Storage: `IBalanceLedger balanceLedger`, `IRiskModule riskModule`, `uint64 flagLock` (default `24 hours`).
- Roles: `DEFAULT_ADMIN_ROLE` (governance), `OPERATOR_ROLE` (protocol settlement key; granted to Phase 6 integrators via governance later).
- `flagFor(address user, address asset)` — `onlyRole(OPERATOR_ROLE)`; calls `balanceLedger.markCollateral(user, asset)`. No HF check (flagging never worsens HF).
- `unflagFor(address user, address asset)` — `onlyRole(OPERATOR_ROLE)`:
  1. `uint64 flaggedAt = balanceLedger.flaggedAt(user, asset);`
  2. `require(flaggedAt != 0, NotFlagged());`
  3. `require(block.timestamp >= flaggedAt + flagLock, FlagLockActive(flaggedAt + flagLock));`
  4. `require(riskModule.canUnflag(user, asset), WouldMakeUnhealthy());`
  5. `balanceLedger.unmarkCollateral(user, asset);`
- `setRiskModule(address newRiskModule)` — `onlyRole(DEFAULT_ADMIN_ROLE)`, gated by the project-wide 48h governance timelock. Phase 2 swap point.
- `setFlagLock(uint64 newFlagLock)` — same gating; lets us tune the 24h default without a redeploy.
- `initialize(balanceLedger, riskModule, admin, operator)` — standard proxy initializer.

**Errors:**

```solidity
error NotFlagged();
error FlagLockActive(uint64 unlocksAt);
error WouldMakeUnhealthy();
```

Each error carries enough info for the backend to surface a precise message ("locked until {timestamp}", "repay in full to release collateral", etc).

**Testing requirements (CollateralManager):**

- Role gating: unauthorized caller reverts on `flagFor` / `unflagFor` / `setRiskModule` / `setFlagLock`.
- Flag-lock enforcement: with `vm.warp(flaggedAt + 24 hours - 1)`, expect `FlagLockActive`. With `vm.warp(flaggedAt + 24 hours)`, expect success (given a permissive `RiskModule`).
- HF-gate rejection: stub `RiskModule` returning `false` → expect `WouldMakeUnhealthy`.
- RiskModule swap: `setRiskModule(mockPermissive)` via timelock → previously-blocked unflag now succeeds.
- Non-refresh semantics: call `markCollateral` twice (e.g., two borrow matches reuse the same collateral asset) → `flaggedAt` from the second call equals the first.
- Repay short-circuit: in an integration test with a mock `Centuari`, calling `unmarkCollateral` directly (simulating `Centuari.repay` full-repay path) clears the flag even within the 24h window.

**Testing requirements (RiskModuleStub):**

- `canUnflag` returns true iff `Centuari.totalDebt(user) == 0`.
- `canWithdraw` returns true iff `!usedAsCollateral(user, asset) || totalDebt(user) == 0`.
- Views — no state mutation possible.

**Verification:**

- `forge test --match-contract CollateralManager -vv` green.
- `forge test --match-contract RiskModuleStub -vv` green.
- Storage layout snapshot committed for `CollateralManager`.

---

### Module 2: Centuari.sol migration off Treasury ⚪ NOT STARTED

**Scope:** change `Centuari.sol` to read + write `BalanceLedger` instead of calling `Treasury.sol`. Treasury.sol stays deployed for Phase 1 (users still deposit via it initially — see M3) but loses its role as the source of truth. Additionally, `Centuari.repay()` gains an **auto-unflag-on-debt-clear** loop that iterates `BalanceLedger.flaggedAssetsOf(msg.sender)` and calls `unmarkCollateral` for each asset when the repay brings total debt to zero. The repay path calls `unmarkCollateral` directly (bypassing `CollateralManager`) so the 24h flag-lock does not apply — full repayment is always a clean exit, even within the lock window.

**Addresses concerns:** C1 (auto-flag/auto-unflag keep the flag writes protocol-signed and amortized into settlement/repay gas — zero user signatures, no new spam surface), C2 (Centuari as sole writer for lending/borrowing in Phase 1), and the M1 rollback loophole fix (atomic debt-clear + flag-clear means there is never a window where `totalDebt == 0 && usedAsCollateral == true`).

**Files to modify:**

- `smart-contract-revamp/src/core/centuari/Centuari.sol`
- `smart-contract-revamp/src/core/centuari/CentuariStorage.sol` (add `_balanceLedger` address slot)
- `smart-contract-revamp/src/interfaces/centuari/ICentuari.sol`
- `smart-contract-revamp/test/centuari/Centuari.t.sol` + any scenario tests currently asserting Treasury state

**Collateral toggle surface on Centuari:** the only collateral-related write path on `Centuari.sol` is the auto-unflag loop at the end of `repay()`. There is **no user-callable `setAssetAsCollateralFor` function** on Centuari. Mid-life unflags (while still in debt) go through the separate `CollateralManager.unflagFor()` entry point (Module 1b), which enforces the 24-hour flag-lock + `IRiskModule.canUnflag` gate. Phase 6 integrators call `BalanceLedger.markCollateral` / `unmarkCollateral` directly (or compose through `CollateralManager`). See Module 1 / Module 1b for the full design and Module 9 for the backend endpoint that fronts `CollateralManager`.

**Pseudocode for the repay auto-unflag loop:**

```solidity
function repay(address loanToken, uint256 amount, ...) external {
    // existing repay accounting: debit borrower, reduce debt position
    _debit(msg.sender, loanToken, amount);
    _reduceDebt(msg.sender, amount);

    if (_totalDebt(msg.sender) == 0) {
        address[] memory flagged = balanceLedger.flaggedAssetsOf(msg.sender);
        for (uint256 i = 0; i < flagged.length; ++i) {
            balanceLedger.unmarkCollateral(msg.sender, flagged[i]);
        }
    }
}
```

The loop is O(n) in the number of flagged assets — bounded in practice by the small number of assets a user collateralizes. Gas is amortized into the existing repay tx.

**Mapping of current Treasury calls:**


| Current call                                         | New call                                                                                                                                                                      |
| ---------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `treasury.settle(loanToken, from, to, amount, ...)`  | `balanceLedger.debit(from, loanToken, amount); balanceLedger.credit(to, loanToken, amount);`                                                                                  |
| `treasury.repay(user, token, amount)`                | `balanceLedger.debit(user, token, amount)` (borrower repaying reduces their available) — semantics flip vs. Treasury which was acting on borrower's debt owed to treasury     |
| `treasury.withdrawLendPosition(user, token, amount)` | `balanceLedger.credit(user, token, amount)`                                                                                                                                   |
| `treasury.recordBondMint(...)`                       | Still calls `CentuariBondERC20.mint(...)` directly — this was Treasury bookkeeping only, no BalanceLedger change                                                              |
| `treasury.burnBondForUser(...)`                      | Still calls bond contract directly                                                                                                                                            |
| `treasury.deposit(...)`                              | **Kept** on Treasury as an entry point in Phase 1, but Treasury's `deposit()` now forwards to `balanceLedger.credit(msg.sender, token, amount)` after pulling tokens. See M3. |
| `treasury.withdraw(...)`                             | Deprecated in Phase 1; withdrawals will go through `WithdrawalRegistry` in M4. Keep the function on Treasury but make it revert with `Deprecated()` once M4 is live.          |


**NB:** The `repay` mapping is the subtlest. In the current Treasury, `repay` moves tokens from the borrower into the Centuari "hot" balance. In the BalanceLedger world, the borrower's debt is tracked by Centuari's internal borrow-position accounting, not by BalanceLedger. BalanceLedger only tracks asset custody. So `repay` should: (a) debit the borrower's available balance by `amount`, (b) reduce the borrower's internal debt position in `CentuariStorage` by `amount`, (c) no credit anywhere — the repaid tokens sit in the protocol as "unallocated available" until the next match. Write a test that catches this.

**Testing requirements:**

- Port every existing Centuari test to the new storage model. They must pass 1:1 in semantics.
- Add a fuzz test that matches random lend/borrow pairs and asserts `sum of all users' available == total tokens held by HubDepositor + Centuari + BalanceLedger writers` (no physical collateral lockup, so the invariant collapses to one bucket).
- Verify Centuari has its address whitelisted as an authorized writer during `initialize()`.

**Verification:**

- Full existing test suite (currently 175 tests) still passes.
- New ledger-invariant fuzz test passes 10k runs.

---

### Module 3: Deployment scripts + testnet cutover + HubDepositor ⚪ NOT STARTED

**Scope:** add deployment scripts for BalanceLedger + HubDepositor, update `run-all.sh` orchestration, redeploy full stack on Arbitrum Sepolia. Document the cutover. **Wipe of existing testnet balances is accepted per C8.**

**Addresses concerns:** C9 (Arbitrum hub-native deposit path — no LZ, no solver).

**HubDepositor.sol — hub-native direct deposit/withdrawal:**

- Minimal contract (or equivalent methods on Centuari.sol) that is the single entry point for users already on Arbitrum. Path 1 from Full Architecture §6.5.1.
- `deposit(asset, amount)` — `safeTransferFrom(msg.sender, this, amount)` then `balanceLedger.credit(msg.sender, asset, amount)` in the same transaction. No intent, no solver, no LayerZero.
- `payout(user, asset, amount)` — called by `WithdrawalRegistry` when the withdrawal target chain is Arbitrum itself. Releases tokens directly from the hub contract's custody. No LZ message.
- Registered as an authorized writer on BalanceLedger.

**Decision (inline):** keep `HubDepositor.sol` as a *separate contract* rather than folding into Centuari.sol. Keeps Centuari.sol focused on lending/borrowing logic and isolates the token-custody surface. Same pattern as Phase 1B where cross-chain contracts are separate.

**Files to create/modify:**

- `smart-contract-revamp/src/core/cross-chain/HubDepositor.sol` (new — minimal custody + credit/payout contract)
- `smart-contract-revamp/src/interfaces/cross-chain/IHubDepositor.sol`
- `smart-contract-revamp/test/cross-chain/HubDepositor.t.sol`
- `smart-contract-revamp/script/DeployBalanceLedger.s.sol` (new — ERC1967 proxy deploy, initial admin = deployer)
- `smart-contract-revamp/script/DeployHubDepositor.s.sol` (new)
- `smart-contract-revamp/script/DeployCentuari.s.sol` (modify — pass BalanceLedger address into initializer)
- `smart-contract-revamp/script/ConfigureBalanceLedger.s.sol` (new — register Centuari + HubDepositor as authorized writers via the testnet `FORCE_ADMIN_WRITER_REGISTRATION` path)
- `smart-contract-revamp/bin/run-all.sh` (modify — add steps for BalanceLedger and HubDepositor)
- `smart-contract-revamp/bin/export-abi.sh` (modify — export BalanceLedger + HubDepositor ABIs)
- `smart-contract-revamp/deployments/deploy-arbitrum-sepolia-latest.json` (regenerated output)

**Testnet-only shortcut:** add a `FORCE_ADMIN_WRITER_REGISTRATION` flag to BalanceLedger that allows instantly adding writers without the 48h wait. Must be disabled before mainnet. Guard with a hardcoded chainId check or a deployment-time constant.

**Verification:**

- `./bin/run-all.sh` deploys the full stack to Arbitrum Sepolia.
- `deployments/deploy-arbitrum-sepolia-latest.json` contains BalanceLedger proxy address.
- Manually call `Centuari.deposit()` via cast, confirm BalanceLedger available balance updated for the depositor.
- Manually place a lend + borrow match via the existing settlement flow, confirm balances flow through BalanceLedger, not Treasury.
- Export ABIs and verify they end up in `abi/` for downstream services.

---

## Phase 1B — Hub Cross-Chain Contracts

### Module 4: WithdrawalRegistry + HubIntentSettler + SettlementLedger ⚪ NOT STARTED

**Scope:** the three hub-side cross-chain contracts. Withdrawal state machine, solver intent settlement, solver reimbursement tracking.

**Addresses concerns:** C5 (intent fill race — this module implements the hub half), C10 (events emitted here — `WithdrawalRequested`, `WithdrawalStateChanged`, `IntentFilled`, `SettlementMatched` — are the exact ones the eager-path services and the indexer tail both consume through the shared `applyOnChainEffect` helper).

**Files to create:**

- `smart-contract-revamp/src/core/cross-chain/WithdrawalRegistry.sol` + storage/interface/errors/events
- `smart-contract-revamp/src/core/cross-chain/HubIntentSettler.sol` + interface
- `smart-contract-revamp/src/core/cross-chain/SettlementLedger.sol` + interface
- `smart-contract-revamp/src/libraries/cross-chain/IntentTypes.sol` — ERC-7683 struct definitions
- `smart-contract-revamp/test/cross-chain/WithdrawalRegistry.t.sol`
- `smart-contract-revamp/test/cross-chain/HubIntentSettler.t.sol`
- `smart-contract-revamp/test/cross-chain/SettlementLedger.t.sol`
- `smart-contract-revamp/script/DeployCrossChainHub.s.sol`

**WithdrawalRegistry — state machine:**
`PENDING → PROCESSING → COMPLETED` (and `FAILED` as terminal).

- `requestWithdrawal(user, asset, amount, targetChainId)` — entry called from Centuari.sol OR directly on-chain by any caller (including Phase 6 integrators). **First action: on-chain HF gate** — `require(riskModule.canWithdraw(user, asset, amount), WithdrawalBlockedByHF())`. This is the single uniform HF enforcement point that closes the M1-rollback loophole: any caller, whether the backend (app-user path) or a direct-contract caller (integrator path), goes through the same check. Phase 1 stub `RiskModule` rejects if the user has any debt and the asset is flagged; Phase 2 real `RiskModule` computes post-withdrawal HF. `WithdrawalRegistry` reads the same `IRiskModule` pointer as `CollateralManager` (both stored in a shared governance-managed registry contract OR both configured via the same setter signature) so the Phase 2 swap is atomic across both gates. After the HF gate passes, moves `BalanceLedger.available → (deducted)` and records PENDING.
- `authorize(requestId)` — moves to PROCESSING. Sends LayerZero message to target chain's `SpokePayout`.
- `markCompleted(requestId)` — called on LZ ack. Moves to COMPLETED.
- `markFailed(requestId)` — on timeout/failure. Refunds user's `BalanceLedger.available`.
- SLA: 4h. After 4h in PROCESSING, off-chain monitor escalates.

**Error:** `error WithdrawalBlockedByHF();` — surfaced to the frontend so users see "would make your position unhealthy" rather than a generic revert.

**Testing additions for the HF gate:**

- With a flagged asset and `totalDebt > 0`: `requestWithdrawal` reverts with `WithdrawalBlockedByHF`.
- With a flagged asset and `totalDebt == 0`: succeeds.
- With an unflagged asset and `totalDebt > 0`: succeeds (not collateral).
- Swap `RiskModule` to a permissive mock via governance and re-run the flagged-with-debt case: now succeeds, proving the Phase 2 swap is zero-code-change in `WithdrawalRegistry`.

**HubIntentSettler — solver flow (no user signatures; LZ-proof based):**

- `fillFor(depositId, user, asset, amount, sourceChainId, lzProof)` — solver calls after seeing a `DepositInitiated` event on a spoke. `lzProof` is a LayerZero message (dispatched by `SpokeDepositGateway` as part of its own `deposit()` call) carrying `(depositId, user, asset, amount, sourceChainId)`. The contract verifies the message originated from the registered `SpokeDepositGateway` on the expected chain, rejects replays by tracking used `depositId`s, validates the solver has pulled actual USDC into the hub contract (Invariant #6 — balance-delta check), credits `BalanceLedger.available[user] += amount`, registers a solver reimbursement obligation with `SettlementLedger`, and emits `SolverFillRegistered(depositId, solver, amount)`.
- `markNoFill(depositId)` — keeper callable after the fill window (e.g., 5 minutes) passes with no `fillFor` for this `depositId`. Records the no-fill state and sends a LayerZero proof-of-non-fill message back to `SpokeDepositGateway` on the source chain so the user can reclaim their escrow.
- No EIP-712 signing. No user-constructed intent. The spoke deposit event is the sole source of truth.

**SettlementLedger — reimbursement tracking:**

- `register(orderId, solver, amount)` — called by HubIntentSettler on fill.
- `match(orderId, bridgedAmount)` — called by Sweeper Bot after bridge confirmation; releases `bridgedAmount` of hub USDC to solver's own BalanceLedger.available (or to solver EOA — decision point, see D1 below).
- Tracks per-orderId state: `REGISTERED → BRIDGED → REIMBURSED`.

**Solver reimbursement destination (locked):** **Solver EOA.** `SettlementLedger.match()` calls `IERC20.safeTransfer(solver, bridgedAmount)` to release reimbursement to the solver's own wallet. Solvers are off-chain agents, not protocol users. BalanceLedger stays free of operational accounts.

**Testing requirements:**

- WithdrawalRegistry: unit tests for every state transition; SLA timeout test with `vm.warp`.
- HubIntentSettler: test `fillFor` reverts if the solver did not actually transfer tokens (Invariant #6 — balance-delta check); test LZ-proof origin validation (must come from the registered `SpokeDepositGateway` on the declared sourceChainId); test `depositId` replay protection; test `markNoFill` only callable after the fill window.
- SettlementLedger: test full register → match flow; test out-of-order matching; test match-before-register rejection.
- **Cross-contract invariant test:** after a complete ERC-7683 intent fill + sweep + reimburse, total hub USDC + solver USDC == original user USDC (no tokens created or destroyed).

**Verification:**

- `forge test --match-path 'test/cross-chain/*' -vv` passes.
- Deploy to Arbitrum Sepolia via `DeployCrossChainHub.s.sol`.
- Simulate an end-to-end intent fill with a mock solver EOA, confirm BalanceLedger credited + SettlementLedger entry created.

---

## Phase 1C — Spoke Chain Contracts

### Module 5: Spoke contracts + LayerZero DVN wiring ⚪ NOT STARTED

**Scope:** the three spoke-side contracts that live on the **four spoke chains only: Base Sepolia, Ethereum Sepolia, BNB Testnet, Polygon Amoy**. No spoke deployment on Arbitrum (hub uses `HubDepositor` from M3 per C9). Also adds LayerZero V2 + Circle CCTP dependencies to the Foundry project.

**Addresses concerns:** C5 (spoke refund gating — this is where `SpokeDepositGateway` is built from scratch, since the feat branch doesn't have it), C7 (DVN config).

**Files to create:**

- `smart-contract-revamp/lib/layerzero-v2/` (git submodule)
- `smart-contract-revamp/lib/cctp/` (git submodule for Circle's TokenMessenger interfaces)
- `smart-contract-revamp/remappings.txt` (add LZ + CCTP paths)
- `smart-contract-revamp/src/core/cross-chain/spoke/SpokeVaultStable.sol`
- `smart-contract-revamp/src/core/cross-chain/spoke/SpokePayout.sol`
- `smart-contract-revamp/src/core/cross-chain/spoke/SpokeDepositGateway.sol` **(this is new — absent from feat branch)**
- Matching interfaces + errors + events
- `smart-contract-revamp/test/cross-chain/spoke/*.t.sol`
- `smart-contract-revamp/script/DeployCrossChainSpoke.s.sol` — parameterized by target chainId
- `smart-contract-revamp/config/layerzero-dvn-testnet.json` — DVN stack configuration per pathway

**SpokeVaultStable:**

- `deposit(asset, amount)` — user deposit into spoke escrow.
- `sweepToHub(asset, amount, hubAddress)` — Sweeper calls. Burns via CCTP for USDC, or sends via LZ OFT for USDT/USDe.
- `HIGH_WATER_MARK` / `LOW_WATER_MARK` config per §6.4.3.
- View functions for Sweeper monitoring.

**SpokePayout:**

- `release(user, asset, amount)` — callable only after `WithdrawalRegistry` authorization arrives via LayerZero.
- Queue mechanism if buffer insufficient (queues the withdrawal until Sweeper replenishes).

**SpokeDepositGateway — the missing piece (user-driven, no signing):**

- `deposit(asset, amount, hubRecipient)` — called directly by the user from their wallet. Pulls tokens via `safeTransferFrom`, generates `depositId = keccak256(block.chainid, msg.sender, nonce)`, emits `DepositInitiated(depositId, user, asset, amount, hubRecipient)`, and dispatches a LayerZero message to `HubIntentSettler` on Arbitrum carrying `(depositId, user, asset, amount, sourceChainId)`. The LZ message acts as proof-of-deposit for the solver's subsequent `fillFor` call.
- `permitAndDeposit(asset, amount, hubRecipient, deadline, v, r, s)` — one-click variant for EIP-2612 tokens. Consumes a permit signature (still just the wallet popup asking for approval, not an EIP-712 intent) and calls `deposit` in the same tx.
- `releaseToSolver(depositId, lzFillProof)` — called by the solver after they've filled on the hub. `lzFillProof` is the LayerZero message from `HubIntentSettler` attesting to the fill. Releases the escrowed tokens to the solver (this is what makes the Sweeper's bridge job unnecessary for the fast path — on spokes where `releaseToSolver` works, the solver is reimbursed directly on the spoke without bridging; the Sweeper only handles the slow-path top-up flow). Note: for simplicity in Phase 1 we can also pay the solver entirely via the Sweeper's bridge path and skip `releaseToSolver` — decision below.
- `refund(depositId)` — **user-callable, LayerZero-gated.** Requires a `lzNoFillProof` from `HubIntentSettler.markNoFill()`. If the proof is valid and fresh, releases the escrowed tokens back to the original depositor. Keeper in Module 6 is responsible for triggering `markNoFill` on the hub after the fill timeout; user then calls `refund` on the spoke to reclaim.

**Reimbursement decision (locked):** Phase 1 uses the **Sweeper bridge path** for solver reimbursement (simpler, one code path). `releaseToSolver` is NOT implemented in Phase 1 — the escrowed spoke tokens stay in `SpokeDepositGateway` until the Sweeper's outbound flow bridges them to the hub and `SettlementLedger.match()` reimburses the solver's EOA. This adds 5–20 min to reimbursement latency but keeps the contract surface minimal.

**LayerZero DVN configuration:**

- For testnet: configure 2-of-2 DVN per pathway across **all four spoke ↔ hub pathways**: Arbitrum Sepolia ↔ Base Sepolia, Arbitrum Sepolia ↔ Ethereum Sepolia, Arbitrum Sepolia ↔ BNB Testnet, Arbitrum Sepolia ↔ Polygon Amoy.
- Primary DVN: LayerZero Labs DVN (available everywhere). Secondary DVN: TBD per chain (see D7). For any pathway where the intended secondary isn't available on testnet, fall back to 1-of-1 LayerZero Labs DVN with a TODO to raise to 2-of-2 before mainnet.
- Create a `ConfigureDVN.s.sol` script that calls `OAppOptionsType3.setEnforcedOptions` + `EndpointV2.setConfig` per pathway.
- Hard-code the config values in `config/layerzero-dvn-testnet.json` keyed by `{hubChainId, spokeChainId}` and load them in the script.
- **Test:** deploy on Arbitrum Sepolia + each spoke, send a dummy LZ message per pathway, confirm it arrives.

**Bridge routing per spoke (USDC path):**

- Base Sepolia: CCTP v2 (pending D5 confirmation)
- Ethereum Sepolia: CCTP v2 (pending D5 confirmation)
- BNB Testnet: LayerZero OFT fallback (CCTP likely unavailable)
- Polygon Amoy: LayerZero OFT fallback (CCTP likely unavailable)
- Capture the routing map in `smart-contract-revamp/config/bridge-routing.json` and read it in both M5 (SpokeVaultStable bridge selection) and M7 (Sweeper bridge selection) so there's one source of truth.

**Testing requirements:**

- Fork tests against Arbitrum Sepolia + Base Sepolia where possible.
- SpokeDepositGateway: test the refund race — a test where solver fills on hub AND spoke tries to refund; the spoke must reject refund.
- CCTP mock for unit tests (Circle provides testnet TokenMessenger).

**Verification:**

- `forge test` passes locally with CCTP + LZ mocks.
- Spoke contracts deploy to Base Sepolia via `DeployCrossChainSpoke.s.sol --chainId 84532`.
- LayerZero DVN config committed to chain, verified via block explorer.
- End-to-end manual test: deposit USDC to `SpokeVaultStable` on Base Sepolia, confirm it's bridgeable to Arbitrum Sepolia via CCTP (without the solver path yet — that's M6).

---

## Phase 1D — Off-Chain Services

### Module 6: Solver Service ⚪ NOT STARTED

**Scope:** new standalone Node.js/TypeScript service that monitors ERC-7683 intent broadcasts, validates them, and calls `HubIntentSettler.fillFor` on Arbitrum hub using the solver's own capital.

**Addresses concerns:** C4 (document capital requirement + make it a config), C5 (solver must not fill past deadline), C10 (solver eagerly applies DB mutations after its own on-chain txs via the shared helper from Module 8).

**Files to create:**

- `solver-service/` — new top-level directory
- `solver-service/package.json` — Node 22, Viem, Zod, Redis, NATS
- `solver-service/src/index.ts` — main entry
- `solver-service/src/deposit-watcher.ts` — subscribes to `DepositInitiated` events on all 4 spoke `SpokeDepositGateway` contracts via Viem `watchEvent`. No webhook, no backend coupling.
- `solver-service/src/deposit-validator.ts` — validates asset is whitelisted, amount within per-spoke + per-fill caps, source chain is recognized, `depositId` not already filled (check hub state).
- `solver-service/src/filler.ts` — waits for the LayerZero proof-of-deposit message to arrive on Arbitrum (or fetches it from the LZ scan API), then calls `HubIntentSettler.fillFor(depositId, ..., lzProof)`. Handles nonce management. **After the fill tx lands**, imports `applyOnChainEffect` from the shared helper (Module 8) and eagerly: (a) flips `intent_order.state` from `BROADCAST` → `FILLED`, (b) credits `user_balance.available += filledAmount` for the user, (c) stamps idempotency columns (`applied_by_tx_hash`, `applied_by_log_index`, `applied_by_block_hash`, `applied_by_block_number`) on both rows so the indexer tail skips them. If the verify call fails (receipt not found, log mismatch), the mutation is skipped and the indexer will pick it up as safety net.
- `solver-service/src/no-fill-keeper.ts` — secondary loop that calls `HubIntentSettler.markNoFill(depositId)` for any depositId older than the fill window that the solver chose NOT to fill (e.g., cap exceeded). This unblocks the user's refund path on the spoke.
- `solver-service/src/capital-manager.ts` — tracks solver's own BalanceLedger + per-spoke 24h rolling volume; enforces `max-fill = min(intentAmount, capitalRemaining, perSpokeCap)`
- `solver-service/src/config.ts` — loads env: `SOLVER_PRIVATE_KEY`, `PER_SPOKE_CAP_USD`, `MAX_FILL_AMOUNT_USD`, `HUB_RPC_URL`, `HUB_INTENT_SETTLER_ADDRESS`, supported spoke list
- `solver-service/src/__tests__/*.test.ts` — Jest
- `solver-service/Dockerfile`
- `docker-compose.yml` (modify — add solver-service)

**Capital bootstrap for testnet:** start with a fixed $50k per-spoke cap hardcoded as default, using the deployer's own funded hot wallet.

**Operational:**

- Prometheus metrics endpoint: `solver_capital_available`, `solver_fill_success_count`, `solver_fill_failure_count`, `solver_fill_latency_ms`.
- Alert if `solver_capital_available < 2 × MAX_FILL_AMOUNT_USD` (per C4).

**Testing requirements:**

- Unit tests for intent validation, capital capping.
- Integration test against a local Anvil fork with deployed hub contracts.

**Verification:**

- Broadcast a test intent manually → solver picks it up, fills on hub, event emitted, BalanceLedger credited.
- Kill the solver mid-fill → it recovers on restart without double-filling.

---

### Module 7: Sweeper Bot ⚪ NOT STARTED

**Scope:** new service that moves real tokens from spoke to hub (after solver fills), and from hub to spoke (to replenish withdrawal buffers). Matches bridge arrivals against `SettlementLedger` to release solver reimbursement.

**Addresses concerns:** C10 (sweeper eagerly applies DB mutations after its bridge + `SettlementLedger.match` txs via the shared helper from Module 8; indexer tails as safety net).

**Files to create:**

- `sweeper-bot/` — new top-level directory
- `sweeper-bot/package.json`
- `sweeper-bot/src/index.ts`
- `sweeper-bot/src/inbound-flow.ts` — Sweeper Flow A from §6.4.1 (spoke → hub after solver fill)
- `sweeper-bot/src/outbound-flow.ts` — Sweeper Flow B (hub → spoke to replenish)
- `sweeper-bot/src/bridge-client.ts` — wraps Circle CCTP + LayerZero OFT calls
- `sweeper-bot/src/water-marks.ts` — `HIGH_WATER_MARK = 3x rolling 24h`, `LOW_WATER_MARK = 1x rolling 24h` per config
- `sweeper-bot/src/ledger-matcher.ts` — calls `SettlementLedger.match(orderId, bridgedAmount)` after bridge confirms. **After the match tx lands**, imports `applyOnChainEffect` from the shared helper (Module 8) and eagerly: (a) flips `intent_order.state` from `FILLED` → `SETTLED`, (b) updates solver-reimbursement bookkeeping, (c) stamps idempotency columns on the affected rows. Verify failures fall through to the indexer safety net.
- `sweeper-bot/Dockerfile`
- `docker-compose.yml` (modify — add sweeper-bot)

**Monitoring:**

- Prometheus: `sweeper_pending_settlements`, `sweeper_bridge_latency_ms`, `sweeper_last_event_age_s`.
- Alert if `sweeper_last_event_age_s > 1800` (30 min = stale; backup Sweeper should take over).

**Backup strategy:** primary is the Centuari-run Sweeper. Gelato-based backup is a Phase 2+ concern per architecture. For Phase 1 testnet, a single Sweeper is acceptable; document the SPOF.

**Verification:**

- After M6's end-to-end fill test, confirm Sweeper detects the event, bridges via CCTP, calls `SettlementLedger.match`, solver is reimbursed.
- Manually drain a spoke's `SpokeVaultStable` below `LOW_WATER_MARK`, confirm Sweeper replenishes from hub.

---

### Module 8: indexer-v2 from scratch (custom, no framework) ⚪ NOT STARTED

**Scope:** brand-new custom Node.js/TypeScript indexer. **Ponder explicitly rejected** — the previous attempt hit dead ends because Ponder's enforced schema model and handler abstraction did not fit multi-chain state rollups (e.g., reflecting a single user's balance from events on hub + all four spokes in one `UserBalance` row). We build our own with the same stack conventions as `backend-v2`: TypeScript, pnpm, Viem, raw `pg`, Biome. Docker-compose already expects `indexer-v2/` at port 42069; directory does not exist yet.

**Addresses concerns:** C6 (custom indexer, not Ponder), C10 (indexer is the safety-net writer; eager-path services also write through the shared idempotency helper).

**Architecture:**

- **Event watcher layer:** one `ChainWatcher` per chain (hub + 4 spokes = 5 watchers). Each uses Viem `createPublicClient` with a WebSocket transport (falling back to HTTP polling) and `watchEvent` / `getLogs` per contract on that chain. A `BlockCursor` table per chain tracks the last fully-processed block; on restart, the watcher replays from `lastBlock + 1` to current.
- **Reorg handling:** store each event with `blockNumber`, `blockHash`, `logIndex`. On every new head, compare the chain's recent N-block hashes against stored hashes; if a divergence is found, delete rows with block > fork-point and replay. N = 12 for hub (Arbitrum finality), N = 64 for Ethereum Sepolia, N = 32 for others. Configurable per chain.
- **Event processors:** each contract has a processor module that takes a decoded event and writes domain entities transactionally using `pg` client `BEGIN/COMMIT`. All writes for a single block on a single chain happen in one transaction so the block cursor + entity updates are atomic.
- **REST API layer:** lightweight Fastify server (Fastify chosen over Hono for node-native ergonomics and because backend-v2 already uses Fastify-style plugins under NestJS). Exposes the endpoints the backend + matching engine + frontend need.
- **No GraphQL.** REST only. Matches backend-v2 conventions and avoids a second query language.

**Files to create:**

- `indexer-v2/` — new top-level directory
- `indexer-v2/package.json` — `viem`, `pg`, `fastify`, `zod`, `pino`, `dotenv`; dev: `tsx`, `@biomejs/biome`, `typescript`
- `indexer-v2/tsconfig.json` — ES2022, strict, nodenext
- `indexer-v2/biome.json` — copy from backend-v2
- `indexer-v2/.env.example`
- `indexer-v2/Dockerfile` — multi-stage, Node 22-alpine
- `indexer-v2/migrations/001_init.sql` — raw Postgres schema (see entities below)
- `indexer-v2/migrations/runner.ts` — simple sequential `.sql` migration runner (pattern used by matching-engine already)
- `indexer-v2/src/index.ts` — entry point: loads config, runs migrations, starts all ChainWatchers, starts Fastify
- `indexer-v2/src/config.ts` — Zod-validated env schema: `DATABASE_URL`, per-chain RPC URLs, contract addresses per chain, start block per chain
- `indexer-v2/src/db/client.ts` — shared `pg.Pool`
- `indexer-v2/src/db/queries.ts` — typed query helpers for each entity
- `indexer-v2/src/chain/chain-watcher.ts` — generic ChainWatcher class, takes a chain config + list of (contract, processor) pairs
- `indexer-v2/src/chain/reorg-detector.ts` — block-hash comparison logic
- `indexer-v2/src/shared/apply-on-chain-effect.ts` — **shared idempotency helper (C10).** Exported for re-use by backend-v2, settlement-engine, solver-service, and sweeper-bot. Takes `(txHash, expectedEventSelector, expectedArgsPredicate, mutationFn)`. Fetches the receipt via Viem, verifies status and event, and applies the mutation inside a transaction that also stamps `applied_by_tx_hash`, `applied_by_log_index`, `applied_by_block_hash`, `applied_by_block_number` on the affected row. Skips the write if a row is already stamped with the same tx hash — idempotent across the eager path and the indexer tail.
- `indexer-v2/src/processors/balance-ledger.processor.ts` — handles `Credited` / `Debited` → updates `user_balance.available`, and `CollateralFlagSet(user, asset, used, flaggedAt)` → updates `user_balance.used_as_collateral` + `user_balance.flagged_at` with the C10 idempotency stamps. The indexer is the authoritative read path for both the balance and the flag.
- `indexer-v2/src/processors/centuari.processor.ts` — handles Order / Match / Repay / Bond mint events. When `Centuari.repay()` triggers the auto-unflag loop, the resulting `CollateralFlagSet(..., used=false)` events come through `balance-ledger.processor.ts` above — this processor does not need to touch the flag column directly.
- `indexer-v2/src/processors/hub-depositor.processor.ts` — handles `Deposit` / `Payout` events on Arbitrum
- `indexer-v2/src/processors/hub-intent-settler.processor.ts` — handles `SolverFillRegistered` / `IntentExpired`
- `indexer-v2/src/processors/withdrawal-registry.processor.ts` — handles state transitions on `WithdrawalRequest`
- `indexer-v2/src/processors/settlement-ledger.processor.ts` — handles `Registered` / `Bridged` / `Reimbursed`
- `indexer-v2/src/processors/spoke-vault.processor.ts` — handles spoke deposits
- `indexer-v2/src/processors/spoke-intent-settler.processor.ts` — handles `OrderOpened` / `SettledWithProof` / `Refunded`
- `indexer-v2/src/api/server.ts` — Fastify bootstrap
- `indexer-v2/src/api/routes/balance.ts` — `GET /balance/:user` + `GET /balance/:user/:asset`
- `indexer-v2/src/api/routes/collateral.ts` — **read-only** `GET /collateral/:user/:asset` returning `{ used: boolean, flaggedAt: number | null, unlocksAt: number | null }`. Flag writes happen on-chain via `CollateralFlagSet` events and flow through `balance-ledger.processor.ts` — there is **no internal write endpoint**. The old `PUT /internal/collateral/:user/:asset` from the earlier draft is removed along with the backend module that called it (see Module 9).
- `indexer-v2/src/api/routes/withdrawals.ts` — `GET /withdrawals/:user`
- `indexer-v2/src/api/routes/intents.ts` — `GET /intents/:user` + `GET /intents/:orderId`
- `indexer-v2/src/api/routes/portfolio.ts` — `GET /portfolio/:user` (aggregates balance + open withdrawals + in-flight intents in one call for frontend)
- `indexer-v2/src/api/routes/health.ts` — `GET /health` reports per-chain cursor lag
- `indexer-v2/src/abi/` — generated TypeScript ABI constants imported from `smart-contract-revamp/abi/` via a small `copy-abi.ts` script run on build

**Postgres schema (migrations/001_init.sql — sketch):**

```sql
CREATE TABLE block_cursor (
  chain_id BIGINT PRIMARY KEY,
  last_block BIGINT NOT NULL,
  last_block_hash TEXT NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE user_balance (
  user_address BYTEA NOT NULL,
  asset BYTEA NOT NULL,
  available NUMERIC(78,0) NOT NULL DEFAULT 0,
  in_orders NUMERIC(78,0) NOT NULL DEFAULT 0,       -- Phase 1: always 0
  in_yield_router NUMERIC(78,0) NOT NULL DEFAULT 0, -- Phase 1: always 0
  used_as_collateral BOOLEAN NOT NULL DEFAULT FALSE, -- on-chain HF flag, mirrored from CollateralFlagSet event
  flagged_at BIGINT,                                  -- unix seconds; mirrors BalanceLedger._flaggedAt; NULL when used_as_collateral=false
  -- C10 idempotency stamps: last on-chain effect applied to this row
  applied_by_tx_hash BYTEA,
  applied_by_log_index INT,
  applied_by_block_hash BYTEA,
  applied_by_block_number BIGINT,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_address, asset)
);
-- Note: NO `collateral` column. Collateral is virtual/HF-gated, not a balance bucket.
-- Note: `used_as_collateral` + `flagged_at` are now driven by the on-chain
-- `CollateralFlagSet(user, asset, used, flaggedAt)` event (emitted from
-- `BalanceLedger.markCollateral`/`unmarkCollateral`). Both the settlement-engine
-- (auto-flag at match), Centuari.repay (auto-unflag at repay-to-zero), and
-- CollateralManager.unflagFor (mid-life unflag) fire this event. The backend's
-- `applyOnChainEffect` helper stamps `applied_by_*` eagerly on the unflagFor path;
-- indexer-v2 stamps them on the auto paths.

CREATE TABLE deposit_event (
  id TEXT PRIMARY KEY, -- chain_id:tx_hash:log_index
  chain_id BIGINT NOT NULL,
  user_address BYTEA NOT NULL,
  asset BYTEA NOT NULL,
  amount NUMERIC(78,0) NOT NULL,
  source_chain BIGINT NOT NULL,
  tx_hash BYTEA NOT NULL,
  block_number BIGINT NOT NULL,
  block_hash BYTEA NOT NULL,
  log_index INT NOT NULL,
  timestamp TIMESTAMPTZ NOT NULL
);
CREATE INDEX ON deposit_event (user_address, timestamp DESC);

CREATE TABLE withdrawal_request (
  request_id BYTEA PRIMARY KEY,
  user_address BYTEA NOT NULL,
  asset BYTEA NOT NULL,
  amount NUMERIC(78,0) NOT NULL,
  target_chain BIGINT NOT NULL,
  state TEXT NOT NULL, -- PENDING|PROCESSING|COMPLETED|FAILED
  created_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL,
  completed_at TIMESTAMPTZ,
  -- C10 idempotency stamps for the LAST state-transition tx
  applied_by_tx_hash BYTEA,
  applied_by_log_index INT,
  applied_by_block_hash BYTEA,
  applied_by_block_number BIGINT
);
CREATE INDEX ON withdrawal_request (user_address, created_at DESC);

CREATE TABLE intent_order (
  order_id BYTEA PRIMARY KEY,
  user_address BYTEA NOT NULL,
  source_chain BIGINT NOT NULL,
  asset BYTEA NOT NULL,
  amount NUMERIC(78,0) NOT NULL,
  solver BYTEA,
  state TEXT NOT NULL, -- OPENED|FILLED|SETTLED|REFUNDED|EXPIRED
  opened_at TIMESTAMPTZ NOT NULL,
  filled_at TIMESTAMPTZ,
  reimbursed_at TIMESTAMPTZ,
  -- C10 idempotency stamps for the LAST state-transition tx
  applied_by_tx_hash BYTEA,
  applied_by_log_index INT,
  applied_by_block_hash BYTEA,
  applied_by_block_number BIGINT
);
CREATE INDEX ON intent_order (user_address, opened_at DESC);

CREATE TABLE bond_token (
  address BYTEA PRIMARY KEY,
  asset BYTEA NOT NULL,
  maturity TIMESTAMPTZ NOT NULL,
  total_supply NUMERIC(78,0) NOT NULL DEFAULT 0
);
```

All timestamp columns are `TIMESTAMPTZ` per project convention.

**Operational notes:**

- Watchers run in a single Node process; each chain's watcher is an async loop with its own error boundary. A crash on one chain does not stop others.
- Pino structured logs piped to stdout.
- Prometheus metrics on `/metrics` (pulled by docker observability stack later): `indexer_block_lag_seconds{chain_id}`, `indexer_events_processed_total{chain_id,contract}`, `indexer_reorg_depth{chain_id}`.

**Testing requirements:**

- Unit tests for each processor: given a decoded event, assert the DB mutation. Use `pg-mem` or a dedicated test Postgres container.
- Reorg replay test: seed blocks 100–110, then replay blocks 105–112 with different hashes, assert rows 106+ deleted and replaced.
- Integration test using Anvil on a single chain: deploy BalanceLedger, run watcher, trigger a credit, assert `user_balance` updated within 2s.

**Verification:**

- `pnpm run dev` starts the indexer, runs migrations, connects to all configured chains, begins tailing.
- `curl localhost:42069/health` returns per-chain block-lag (< 10s for testnet).
- Trigger a deposit via HubDepositor on Arbitrum Sepolia → `GET /balance/0x<user>` returns the updated `available` within 2 seconds.
- Trigger a deposit on Base Sepolia's SpokeVaultStable → `GET /intents/<orderId>` shows the intent moving `OPENED → FILLED → SETTLED`.

---

### Module 9: backend-v2 + settlement-engine + matching-engine updates ⚪ NOT STARTED

**Scope:** update existing services to read from indexer-v2 + interact with new contracts.

**Addresses concerns:** C3 (matching engine reads BalanceLedger for validation), C10 (every service that submits an on-chain tx eagerly applies the DB mutation through the shared helper from Module 8; indexer tails the same events as the safety net).

**backend-v2 changes:**

- `backend-v2/src/deposit/` — no signing, no intent forwarding. The frontend drives the deposit tx directly against `HubDepositor` (Arbitrum) or `SpokeDepositGateway` (spokes), then POSTs the resulting `txHash + sourceChainId` back to `POST /deposit/verify`. The backend fetches the receipt via Viem, calls the shared `applyOnChainEffect` helper to verify the expected event (`HubDepositor.Deposited` or `SpokeDepositGateway.DepositInitiated`), and eagerly applies the resulting DB mutation (`user_balance.available += amount` for hub-direct, or `deposit_event` row + `intent_order` seed for spoke). Returns the updated state to the frontend so the UI reflects it without waiting on the indexer. Indexer tails the same events as the safety net per C10. `GET /deposit/targets` returns the supported source-chain metadata. `GET /deposit/:depositId` reads the canonical row for progress polling. The existing `POST /deposit` Treasury-writing endpoint is removed. No webhook to solver — the solver watches chain events directly.
- `backend-v2/src/withdraw/` — replace `Treasury.withdraw` call path. New flow: backend calls `Centuari.requestWithdrawal(user, asset, amount, targetChain)` which hits `WithdrawalRegistry`, then eagerly applies the PENDING-state row via `applyOnChainEffect`. Subsequent state transitions (PROCESSING on LZ send, COMPLETED on LZ ack, FAILED on timeout) are applied the same way when the backend/settlement-engine submits each follow-up tx. Indexer tails as safety net per C10.
- `backend-v2/src/portfolio/` — replace Treasury balance queries with indexer-v2 REST calls. Surface the 3 sub-states (`available`, `inOrders`, `inYieldRouter`) plus the per-asset `usedAsCollateral` flag in the portfolio response shape.
- `backend-v2/src/collateral/` — **new module, on-chain-backed.** Single endpoint `POST /collateral/unflag { asset }` gated on Privy JWT. There is **no flag endpoint** — flagging happens implicitly at borrow-match settlement time (see matching-engine/settlement-engine in Module 9 and Settlement.sol auto-flag loop in Module 2). The unflag path:
  1. Reads the user's current flag state + `flagged_at` from indexer-v2 and rejects with HTTP 400 `NotFlagged` if the asset is not flagged.
  2. Rejects with HTTP 409 `FlagLockActive { unlocksAt }` if `now < flagged_at + 24h`.
  3. Submits `CollateralManager.unflagFor(user, asset)` via the protocol settlement key using the shared Viem signer.
  4. On success, eagerly applies the DB mutation through `applyOnChainEffect` (C10): writes `used_as_collateral = false`, `flagged_at = NULL`, stamps `applied_by_*` with the tx/log data. Returns the updated row.
  5. On `CollateralManager` reverts (`FlagLockActive`, `WouldMakeUnhealthy`, `NotFlagged`), maps the custom error to an HTTP 4xx with the decoded reason and does not mutate the DB.
- **Backend rate limit:** 5 `POST /collateral/unflag` calls per user per 24h via Redis counter. Belt-and-suspenders against settlement-key nonce burn across many assets; the on-chain 24h lock already caps throughput per asset.
- **Borrow-order DTO** (`backend-v2/src/orders/`): the borrow POST body gains `collateralAssets: string[]`. Backend validates the array is non-empty and that every listed asset has a positive `available` balance in indexer-v2 before publishing to NATS. The matching engine forwards it unchanged; the settlement engine encodes it per borrower in the `Settlement.settle()` call so the on-chain auto-flag loop can run. See Module 9 matching-engine and Module 2 Settlement changes.
- `backend-v2/src/chain-indexer/` — deprecate; point consumers at indexer-v2 instead.
- `backend-v2/src/core/viem/` — add new contract ABIs.

**settlement-engine changes:**

- `settlement-engine/src/settlement/smartContract.ts` — no Treasury references today per exploration, so minimal change. But: the Settlement.sol contract itself is not changed in Phase 1 (that's Phase 3A's CentuariEndpoint). So settlement-engine's interaction with Settlement.sol is unchanged. Only the post-settlement event indexing moves to indexer-v2.
- Event consumers pointed at indexer-v2 instead of direct chain polling.
- **Auto-flag at match settlement.** `settlement-engine/src/settlement/smartContract.ts` passes `collateralAssets[]` per borrower into the updated `Settlement.settle()` ABI so the on-chain auto-flag loop (Module 2) marks each asset atomically with debt creation. No separate collateral worker, no standalone flag endpoint on the settlement key — the flag write is free-riding on a settlement tx that would happen regardless.

**matching-engine changes:**

- Add `matching-engine/src/services/balance-ledger-client.ts` — Viem client reading `BalanceLedger.getAvailable(user, asset)` with 1-block TTL cache.
- `matching-engine/src/core/matching-engine.ts` — call the client at order validation time. Reject if available < order amount. Document this is a soft check (final enforcement is at settlement per C1).
- `matching-engine/src/types/order.ts` — add `collateralAssets: string[]` to the borrow order schema (non-empty). The engine does not re-validate holdings (backend already did it at DTO validation time); it forwards the array unchanged in the match payload pushed to the Redis `settlement:matches` stream so the settlement engine can encode it into the on-chain `Settlement.settle()` call.
- Update Jest tests that previously mocked Treasury to mock BalanceLedgerClient instead.

**Testing requirements:**

- Backend: integration tests that hit a local indexer-v2 + deployed testnet contracts.
- Matching engine: unit tests with mocked BalanceLedgerClient covering "available < order amount" rejection.

**Verification:**

- Full end-to-end: `POST /deposit` with `sourceChain: arbitrum-sepolia` → Centuari.deposit → BalanceLedger.credit → indexer-v2 picks up event → `GET /portfolio/:user` returns new balance.
- Place a lend order exceeding available balance → matching engine rejects.

---

### Module 10: frontend-revamp cross-chain deposit/withdraw UI + collateral flow ⚪ NOT STARTED

**Scope:** new deposit/withdraw screens supporting the cross-chain flow + balance display showing the 3 sub-states + a collateral multi-select on the borrow form + a read-only collateral badge + countdown-gated unflag button on the portfolio.

**Files to modify:**

- `frontend-revamp/src/app/(app)/portfolio/` — 3-bucket balance display. For Phase 1, only `available` is non-zero (the other two are forward-compat). Each row also shows: a **Collateral** badge when `used_as_collateral = true`, a countdown label ("Unlocks in 18h 42m") driven by `flagged_at + 24h`, and a **Remove as collateral** button that is disabled until the countdown hits zero.
- `frontend-revamp/src/components/centuari-borrow/` — borrow order form gains a **collateral asset multi-select** (checkbox list of the user's deposited assets, default all selected). On submit, shows a confirmation modal: *"These assets will be locked as collateral for at least 24 hours after the match settles. You will not be able to unflag them before then, even after partial repayment. Full repayment will release them immediately. Continue?"* — user must tick an ack box before the submit button enables. The selected assets are posted as `collateralAssets: string[]` on the borrow order body.
- `frontend-revamp/src/components/centuari-deposit/` — source-chain selector with 5 options: **Arbitrum (direct)**, Base Sepolia, Ethereum Sepolia, BNB Testnet, Polygon Amoy. Arbitrum (direct) uses `HubDepositor.deposit()` — single tx, ~15s; the other 4 route through the spoke deposit flow — balance appears on Arbitrum in ~3s after solver fill.
- `frontend-revamp/src/components/centuari-withdraw/` — target-chain selector with the same 5 options. Arbitrum (direct) releases via `HubDepositor.payout()` — instant once WithdrawalRegistry authorizes. The other 4 require a LayerZero message to `SpokePayout` — instant from spoke cash buffer or 5–20 min if the buffer needs replenishing from the Sweeper.
- `frontend-revamp/src/hooks/use-deposit.ts` — single `useWriteContract` call. Arbitrum (direct) → `HubDepositor.deposit(asset, amount)`. Spokes → `SpokeDepositGateway.permitAndDeposit(...)` if EIP-2612, else `approve` + `deposit`. **No `signTypedData`, no intent construction.** Polls `GET /deposit/:depositId` for cross-chain progress (`SPOKE_LOCKED → SOLVER_FILLED → HUB_CREDITED`).
- `frontend-revamp/src/hooks/use-withdraw.ts` — withdrawal state tracking via indexer-v2 polling.
- `frontend-revamp/src/hooks/use-unflag-collateral.ts` — **new hook.** No wallet popup. Calls `POST /collateral/unflag { asset }` with the Privy JWT. Optimistic update on click; rolls back on error. Distinct error paths:
  - `FlagLockActive` (HTTP 409) → toast "Locked until {unlocksAt}", disables button until the countdown elapses.
  - `WouldMakeUnhealthy` (HTTP 400, Phase 1 stub) → toast "Repay in full to release this collateral".
  - `WouldMakeUnhealthy` (HTTP 400, Phase 2 real) → toast "Would drop health factor below 1".
  The hook is purely a backend call; the Phase 2 swap is invisible at the UI layer.
- `frontend-revamp/src/lib/portfolio-data.ts` — indexer-v2 API, returns the 3 sub-states + `usedAsCollateral` + `flaggedAt` per asset.
- `frontend-revamp/src/lib/chain-config.ts` — add spoke chain configs.
- `frontend-revamp/e2e/cross-chain-deposit.spec.ts` — Playwright end-to-end.
- `frontend-revamp/e2e/collateral-flow.spec.ts` — Playwright e2e: (a) place a borrow with `collateralAssets = [USDC]` → collateral badge appears on the portfolio row after settlement; (b) unflag button is disabled with a countdown until `flagged_at + 24h`; (c) direct API call to `POST /collateral/unflag` before 24h returns HTTP 409 `FlagLockActive`; (d) after 24h, unflag while still in debt returns HTTP 400 `WouldMakeUnhealthy` (Phase 1 stub); (e) full repay auto-clears the flag without waiting 24h.

**Verification:**

- `pnpm run test:e2e` passes the new cross-chain deposit test (uses mocked solver or local devnet).
- Manual smoke test: deposit 100 USDC on Base Sepolia from the UI, see balance appear on Arbitrum portfolio within 3 seconds.

---

## Overall Phase 1 Verification (End-to-End)

After all 10 modules merged, the following manual verification must pass before Phase 1 is declared done. This is the "definition of done" for Phase 1.

1. Deposit 100 USDC on Base Sepolia via the frontend. Balance appears in `available` on Arbitrum within 3 seconds. Indexer-v2 shows the intent flow: broadcast → filled → swept → reimbursed. Final state: user's `available` = 100, solver's capital restored, SettlementLedger entry = REIMBURSED.
2. Place a lend order for 50 USDC at 8% APY, 30-day maturity. Matching engine accepts (available > order). Match against a borrower. Settlement batch submitted. Post-settlement: lender has CBT-USDC-YYYY-MM-01 tokens, borrower has 50 USDC in available + debt position in Centuari. BalanceLedger invariant holds.
3. Request withdrawal of 50 USDC to Base Sepolia. Frontend shows "estimated 5–20 min". WithdrawalRegistry enters PENDING → PROCESSING → COMPLETED. User receives USDC on Base Sepolia. BalanceLedger available decremented by 50.
4. Kill the matching engine mid-operation. Restart. Confirm it recovers from Redis + re-reads BalanceLedger; no orders lost, no double fills.
5. Kill the Sweeper mid-bridge. Restart. Confirm it picks up unmatched SettlementLedger entries and retries.
6. Run the invariant test suite: total tokens locked in all contracts == sum of all BalanceLedger balances + all in-flight intents + all in-flight withdrawals + all outstanding CBT supply.

If all 6 pass, Phase 1 is complete. Move to Phase 2 (Risk + Liquidation).

---

## Things Explicitly NOT in Phase 1

To prevent scope creep, the following features from the Full Architecture document are **not** in Phase 1. They belong to later phases and attempting them now will break the modular structure:

- YieldRouter + Aave/Compound/Morpho adapters (Phase 5B).
- AssetBehaviorRegistry (Phase 2A).
- RiskModule + LiquidationEngine (Phase 2B).
- CentuariEndpoint + HSM signing + SettlementBatch (Phase 3A).
- Auto-Rollover / Auto-Refinance / Maturity Engine (Phase 4).
- pCBT vault (Phase 4E).
- On-chain `placeOrder` entry point for third-party integrators (Phase 6 `CentuariRouter`). Phase 1 order placement is fully off-chain via backend + matching engine (Privy-authed, zero signatures, zero gas — same as current staging).
- CentuariRouter + Credit Kit (Phase 6).
- RWA attestation (Phase 2A).
- CBT secondary market / early exit (Phase 5C).
- Keeper Bot infrastructure (Phase 8C).
- Protocol monitoring (Phase 8B) — only basic Prometheus metrics on the new services.

Any pressure to pull these forward must be routed back through the architecture doc and this plan updated.

---

## Resolved Decisions (Locked in for Phase 1)

1. **Hub + spoke chains:** Hub = **Arbitrum Sepolia**. Spokes = **Base Sepolia, Ethereum Sepolia, BNB Testnet, Polygon Amoy**. Four spoke chains total. M5 deploys `SpokeVaultStable` / `SpokePayout` / `SpokeDepositGateway` to all four. M6 (Solver) and M7 (Sweeper) must support all four spokes from day one.
2. **Solver reimbursement destination:** **Solver EOA.** `SettlementLedger.match()` releases reimbursement directly to the solver's wallet, not to a BalanceLedger entry. Keeps BalanceLedger clean of operational accounts.
3. **Spoke refund design:** **Keeper-triggered + LayerZero proof-of-non-fill.** `SpokeDepositGateway.refund()` only executes after a LZ message from hub confirms the intent was not filled. Refund latency: 5–20 min worst case. No double-credit race.
4. **Testnet cutover:** **Clean wipe + redeploy.** Existing Arbitrum Sepolia Treasury balances are discarded. Testers re-deposit via the faucet after redeploy. No migration script.

## Still Open (Need Resolution Before M5 / M6 Start)

- **D5 — CCTP testnet availability per spoke:** Circle CCTP is NOT uniformly available on all 4 target testnets. Known status: Base Sepolia and Ethereum Sepolia have CCTP v2; BNB Testnet and Polygon Amoy do not have reliable CCTP testnet support. For chains without CCTP, **fall back to LayerZero OFT-wrapped USDC** for the USDC bridging path. M5 must verify this per chain before committing bridge selection logic. Document per-spoke bridge routing in `config/bridge-routing.json`.
- **D6 — Solver bootstrap capital:** who funds the testnet solver wallet for the 4 spokes? Recommend team hot wallet, $25k equivalent per spoke on testnet faucet tokens. Needs team confirmation before M6.
- **D7 — LayerZero DVN providers on BNB Testnet + Polygon Amoy:** LayerZero Labs DVN is the safe default across all four, but the "2-of-2" selection for the second DVN differs per chain. Need to confirm Google Cloud DVN / Polyhedra DVN availability per spoke and pin the choice before M5 deploys.

