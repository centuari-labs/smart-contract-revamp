# Centuari Phase 1 — Cross-Chain + BalanceLedger Implementation Plan

> **2026-04-17 update — collateral flag model corrected.** This doc was originally written around an auto-flag-at-settlement / auto-unflag-at-repay model. That behavior has been **reverted**: `Centuari.settleMatch` now flags only the assets the borrower explicitly requested via `MatchData.collateralAssets[]`, and `Centuari.repay` never touches flags. Unflagging always flows through `CollateralManager.unflagFor` (24h lock + `RiskModule.canUnflag`). Read any reference in this file to "auto-flag" or "auto-unflag" through that lens — the authoritative current-state summary lives in [`collateral-loophole-fix-plan.md`](./collateral-loophole-fix-plan.md) under the P1b-explicit section.

## Context

Centuari is migrating from a single-chain, deposit-at-order-time lending protocol (current staging) to a cross-chain, deposit-first, gasless-orders protocol. This plan covers **Phase 1 only** from the Centuari Full Architecture v6 document and `Centuari_Implementation_Plan.pdf`.

**What Phase 1 delivers:** a user can deposit USDC on Base (or any spoke chain), have balance credited on Arbitrum within ~30s-2min via LayerZero-confirmed cross-chain credits (no solver required), lend/borrow against that balance (existing flows), then withdraw back to any supported chain. All tracked through a new `BalanceLedger.sol` with 3 sub-states (`available`, `inOrders`, `inYieldRouter`) plus a per-(user, asset) **on-chain** `usedAsCollateral` flag, auto-set at borrow-match settlement, auto-cleared on full repay, and otherwise lockable for a minimum 24 hours through a new `CollateralManager.sol` wrapper contract — with every unflag and every withdrawal gated by a single `IRiskModule` seam (stub in Phase 1, real HF math in Phase 2). A solver fast-fill layer (~3s deposits) is deferred to a future phase — see "Future: Solver Fast-Fill Layer" section.

**Why this first:** every later phase (Risk/Liquidation, Settlement Upgrade, Maturity Engine, Gasless, DeFi Integration) depends on BalanceLedger's sub-state model. BalanceLedger + cross-chain is the foundation.

**Collateral model — HF-gated, no physical lockup, on-chain flag.** Centuari does NOT lock collateral into a separate balance bucket when a user borrows. Instead, collateral is "virtual": the user flags assets they're willing to use as collateral, and the (Phase 2) RiskModule continuously computes a health factor from the user's `available` balances across all flagged assets against their outstanding debt. Any user-initiated outflow (withdrawal, cross-asset transfer, yield routing) is gated by "post-action HF >= 1". This matches Aave/Compound/Morpho, is strictly more capital-efficient than physical lockup, composes cleanly with Phase 6 on-chain integrators (they only read `available` + HF, not a zoo of lock-sub-states), and avoids per-borrow allocation bookkeeping entirely. **The flag lives on-chain** on `BalanceLedger`, but users never sign or pay gas to set it — flagging is an automatic side effect of the protocol-signed settlement tx that records a borrow match, and unflagging on full repay is an automatic side effect of the protocol-signed repay tx. Mid-life unflagging (while still in debt) goes through a small `CollateralManager.sol` wrapper with a 24-hour flag-lock and a `RiskModule` gate. Phase 1 ships a conservative `RiskModuleStub` (rejects any unflag while debt > 0); Phase 2 swaps in the real oracle-backed `RiskModule` via a single governance call. This design closes the loophole where a user with off-chain collateral state could bypass the backend and call `WithdrawalRegistry` directly to exit with borrowed funds — see Module 1's "Why the flag is on-chain" section and the `CollateralManager` spec below.

**Reference, not gospel:** the branch `feat/centuari-full-implementation` in `smart-contract-revamp/` already contains first-pass versions of `BalanceLedger.sol`, `HubIntentSettler.sol`, `SettlementLedger.sol`, `WithdrawalRegistry.sol`, `SpokeVaultStable.sol`, `SpokePayout.sol` (per exploration). These are cited as "confusing / prone to bug" by the user and are to be treated as reference sketches, not starting points. `SpokeDepositGateway.sol` is missing entirely from that branch. The cross-chain wiring lives on a separate commit (`95dc1c7`) that has not been brought into staging. Off-chain service updates (`backend-v2`, `frontend-revamp`, `settlement-engine`, `matching-engine`, `indexer-v3`) are NOT present on the feat branch — those must be built as part of Phase 1D.

---

## Architectural Concerns (Challenges to the Full Architecture Doc)

Before implementing, the following issues in the architecture must be resolved or explicitly acknowledged. Each one will show up as a concrete decision point during implementation.

### C1. One-click gasless + signatureless UX (perp-DEX style)

User requirement: placing, cancelling, and replacing orders must be single-button — no signing, no gas, no waiting on a wallet popup. Same feel as Hyperliquid / dYdX v4 / Lighter.

This is already achievable with the existing Centuari stack — the current staging build routes orders through the backend (Privy JWT auth) to the matching engine over NATS, with zero per-order on-chain signatures. What Phase 1 changes is WHERE the matching engine gets its balance view (indexer-v3 instead of backend state) and WHERE settlement debits come from (BalanceLedger instead of Treasury). **The order-placement UX does not change: user Privy-auths once per session, every subsequent order is one click.**

**Phase 1 order flow (all off-chain, zero user signatures after Privy session auth):**

1. User opens the app → Privy session established → backend issues session JWT.
2. User clicks "Lend 100 USDC at 8% / 30d" → frontend POSTs `{market, side, price, amount}` to backend with JWT → zero wallet prompts.
3. Backend validates JWT, forwards order to matching engine via NATS.
4. Matching engine reads `BalanceLedger.available(user, asset)` from indexer-v3 (sub-ms lookup on same docker network), subtracts its own per-user Redis reservation counter, accepts the order if `available - reservation >= orderAmount`, and increments the reservation.
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

**Resolution:** the engine reads from **indexer-v3** (Module 8), not directly from chain RPC. The custom indexer maintains an always-current snapshot of `UserBalance` entities via event subscription; the engine queries the indexer's REST/internal API for `available`. Indexer is colocated with the engine (same Docker network) so latency is sub-ms. If the indexer is down, the engine falls back to a direct RPC read cached per block. Reservation tracking (Redis) subtracts from the snapshot. Full consistency is still enforced at settlement, not at order placement.

### C4. Solver capital commitment — deferred to a future phase

Full Architecture §2.7: solver must hold "20% of peak 24h deposit volume per spoke" as hub-side Arbitrum balance. For 5 spokes and any non-trivial volume this is meaningful capital — impractical for a startup with limited liquidity at launch.

**Resolution:** the solver fast-fill layer is **deferred entirely from Phase 1**. Cross-chain deposits use a direct **LZ-confirmed credit** flow instead: `SpokeDepositGateway` escrows the tokens and sends a LayerZero message to the hub, which credits `BalanceLedger.available` on receipt of the LZ proof (~30s-2min latency). A Sweeper Bot bridges the escrowed tokens spoke → hub in the background for custody. This eliminates the solver capital requirement, the Solver Service (M6), and the solver reimbursement tracking (`SettlementLedger`) from Phase 1 scope. The on-chain contracts for the solver path (`HubIntentSettler.fillFor`, `SettlementLedger`) are already built and tested (M4) and remain in the codebase as dormant infrastructure — they can be activated in a future phase when cross-chain volume justifies the capital outlay. See the **"Future: Solver Fast-Fill Layer"** section at the end of this document.

### C5. Cross-chain deposit: no user-signed intents; the on-chain deposit IS the intent (no solver in Phase 1)

User requirement (extended from C1): cross-chain deposits must also be low-signature. User should NOT sign any EIP-712 `GaslessCrossChainOrder`. The only signature the user ever produces for a cross-chain deposit is the on-chain tx that locks their own tokens on the spoke — unavoidable because funds originate in their wallet.

**Phase 1 flow (LZ-confirmed credit, no solver):**

1. User clicks "Deposit 100 USDC from Base" in the frontend.
2. Wallet opens. User confirms ONE tx: `SpokeDepositGateway.deposit(asset, amount, hubRecipient)` on Base Sepolia. If the token supports EIP-2612, this is a single `permitAndDeposit` call (no prior approve). Otherwise it's approve + deposit (two clicks — same as the current staging UX). The user pays gas on Base (cheap).
3. `SpokeDepositGateway` pulls the tokens into its escrow and emits `DepositInitiated(depositId, user, asset, amount, hubRecipient)`. `depositId = keccak256(chainId, tx.origin, nonce)`. **This event is the intent.** No off-chain signing at all.
4. `SpokeDepositGateway` dispatches a LayerZero message to the hub carrying `(depositId, user, asset, amount, sourceChainId)`.
5. The hub's LZ receiver (a new `confirmDeposit` function on `HubIntentSettler`, or a dedicated receiver contract) verifies the LZ message came from the correct `SpokeDepositGateway` on the correct chain, then credits `BalanceLedger.available[user] += amount` and marks the `depositId` as `CREDITED`.
6. User's balance appears on Arbitrum in **~30s-2min** (LayerZero message confirmation latency). No solver capital required.
7. The Sweeper Bot bridges the escrowed tokens from spoke → hub via CCTP or Stargate V2 in the background (5-20 min) for actual token custody on the hub. The BalanceLedger credit already happened in step 5 — the bridge is for custody reconciliation, not for user-facing latency.

**Refund path (simplified — no solver race):**

- If the LZ message fails to arrive on the hub within a configurable timeout (e.g., 30 minutes), the user can call `SpokeDepositGateway.refund(depositId)` to reclaim their escrowed tokens. The refund is gated on either: (a) a timeout check (`block.timestamp >= depositTimestamp + REFUND_WINDOW`) with a hub-side check confirming no credit was issued, or (b) a LayerZero message from hub attesting "no credit recorded for this depositId". The simpler timeout approach (a) is preferred for Phase 1.
- Double-credit is impossible because `confirmDeposit` on the hub marks the `depositId` as `CREDITED` and reverts on replay. The refund path checks that no credit was issued before releasing escrow.

**Impact on module structure:**

- `SpokeDepositGateway` is built from scratch (still absent from the feat branch). It handles escrow + LZ message dispatch + refund. No solver interaction.
- `HubIntentSettler` gains a new `confirmDeposit(depositId, user, asset, amount, sourceChainId)` function callable only by the LZ endpoint (replaces the solver-gated `fillFor` path for Phase 1). The existing `fillFor` function remains in the contract for future solver integration but is not used in Phase 1.
- Frontend deposit hook does NOT call `signTypedData`. It calls `useWriteContract` against `SpokeDepositGateway.permitAndDeposit` (or plain `deposit`).
- Backend does NOT construct or forward signed intents. It surfaces the pending deposit state to the frontend by polling indexer-v3, but the user's wallet drives the deposit directly.

### C6. indexer-v3 must be built from scratch in Phase 1 (custom, not Ponder)

The docker-compose file references `indexer-v3/` but the directory does not exist in the repo. Phase 1D assumes it can "update event schemas" but there is no indexer to update.

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

### C10. Eager DB sync after on-chain calls; indexer-v3 is the safety net, not the fast path

Indexer-v2 tails chain events and is eventually consistent with chain state, but its latency is non-zero (a few hundred ms at best, multiple seconds under load) and it is a separate process that can lag, crash, or be restarted. If every UI read depended on the indexer having already tailed the tx that just landed, the UX would feel slow and inconsistent, and reconciliation bugs would look like "my balance disappeared".

**Resolution — two-writer pattern for every on-chain mutation:**

For every tx that mutates DB-visible state (deposit, settlement, withdrawal authorization, sweeper bridge, etc.), the **service that submitted the tx** is also responsible for **eagerly writing the resulting DB mutation as soon as the tx receipt lands and is verified**. The indexer tails the same event in parallel as a **safety net** — if the eager path fails (service crash mid-verification, network blip, receipt fetch timeout, a reorg that replaces the tx), the indexer backfills from the chain event and the DB converges.

**The pattern:**

1. Service submits tx with Viem, awaits receipt.
2. Service verifies the receipt: `status == success`, expected event logs present, event args match what the service intended to do.
3. If verification passes, service applies the mutation directly to the shared Postgres DB inside a transaction that **also stamps the row with `applied_by_tx_hash` and `applied_by_log_index`**. This stamp is what makes the eager path idempotent with the indexer path.
4. If verification fails (receipt status reverted, wrong event, mismatched args), the service does NOT apply anything — the indexer will either (a) converge later if the tx silently succeeded, or (b) never apply anything if the tx genuinely reverted.
5. The indexer processor for that event type checks `applied_by_tx_hash` before writing: if it's already set to the same tx hash, the indexer skips (no-op). If it's unset or set to a different tx, the indexer applies its mutation. Both writers converge to the same row state.

**Reorg handling stays unchanged:** the indexer's reorg detector compares block hashes on every new head and removes any rows whose `block_hash` was replaced, then replays from the fork point. The eager path stamps `block_hash` + `block_number` alongside `applied_by_tx_hash`, so a reorg-evicted row is cleaned up the same way regardless of which writer created it.

**Consequence for module design:**

- **Settlement engine (Module 9)** updates `user_balance.available` immediately after each successful batch submission; indexer tails `BalanceLedger.Credited/Debited` as backup.
- **Sweeper bot (Module 7)** updates `cross_chain_deposit.state = BRIDGED` immediately after its bridge tx lands; indexer tails as backup. (Phase 1 has no solver reimbursement flow — the Sweeper only bridges escrowed tokens spoke → hub for custody.)
- **Backend deposit module (Module 9)** — when the frontend POSTs a deposit tx hash, the backend fetches the receipt, verifies the `HubDepositor.Deposited` or `SpokeDepositGateway.DepositInitiated` event, and eagerly applies the row update; indexer tails as backup. For cross-chain deposits, the LZ-confirmed credit on the hub is tailed by the indexer as the primary path; the backend eagerly applies the credit if it detects the hub-side event first.
- **WithdrawalRegistry state transitions (Module 9)** — backend updates `withdrawal_request.state` on each authorize / complete / fail tx; indexer tails as backup.
- **Frontend (Module 10)** always reads from the same DB (via backend or indexer REST — they return the same rows). Because the eager path is usually faster than the indexer, the user sees updated state within a few hundred ms of the tx landing, not seconds later.

**What lives on the shared library vs. per-service:**

The verify-then-apply pattern is a small shared helper in `indexer-v3/src/shared/apply-on-chain-effect.ts` (exported for re-use) that takes `(txHash, expectedEventSelector, expectedArgs, mutationFn)` and handles receipt fetch, log parsing, idempotency stamping, and transactional commit. Both the indexer processors and the eager-path services (backend-v2, settlement-engine, sweeper-bot) import it so there is exactly one place where the idempotency invariant is enforced.

**Note on the collateral flag (now on-chain):**

The `usedAsCollateral` flag is on-chain in Phase 1 and is written by one of three paths: (a) auto-flag inside `Settlement.settle()` at borrow match settlement, (b) auto-unflag inside `Centuari.repay()` when debt hits zero, (c) mid-life unflag through `CollateralManager.unflagFor()` gated by the 24h flag-lock + `RiskModule.canUnflag`. All three emit `BalanceLedger.CollateralFlagSet(user, asset, used, flaggedAt)` which indexer-v3 tails into the `user_balance.used_as_collateral` column with the same C10 idempotency stamps as every other event. Whichever service submitted the underlying tx (settlement-engine for settle, backend-v2 for repay and unflag) eagerly applies the mutation via `applyOnChainEffect` so the UI reflects the flag change within a few hundred ms rather than waiting on the indexer tail.

### C11. Spoke-native custody and per-chain liquidity tracking

Not all tokens can be bridged to the hub. Tokens like IDRX (Base/BNB only), XAUT (ETH only), and Ondo RWAs (ETH/BNB only) either lack bridge support (no CCTP/Stargate pool) or don't exist on Arbitrum at all. These tokens use SPOKE_NATIVE custody: the token stays on the spoke where deposited, and the hub tracks only accounting (BalanceLedger) plus a per-chain liquidity map.

**Resolution:** the hub maintains `ChainLiquidity[token][chainId]` alongside BalanceLedger. On SPOKE_NATIVE deposit, the spoke sends an LZ message to hub which credits BalanceLedger AND increments ChainLiquidity. On withdrawal, WithdrawalRegistry checks `ChainLiquidity[token][targetChain] >= amount` and decrements atomically. The frontend shows per-chain liquidity for SPOKE_NATIVE tokens so users can pick a chain with sufficient balance.

**Lending/borrowing for SPOKE_NATIVE tokens:** fully supported via hub accounting. A lender depositing XSGD on Base and a borrower withdrawing XSGD on Polygon works as long as someone else deposited XSGD on Polygon (providing liquidity there). The tokens don't move between chains — only the accounting flows through the hub.

**Limitation:** if all XSGD liquidity is on Base and a borrower wants to withdraw to Polygon, the withdrawal is blocked until someone deposits XSGD on Polygon. This is acceptable for lower-volume exotic tokens. High-volume tokens (USDC, USDT) use BRIDGED custody to avoid this fragmentation.

**No Sweeper rebalancing for SPOKE_NATIVE tokens.** There is no bridge to move XSGD from Base to Polygon even if we wanted to. The liquidity distribution reflects organic deposit patterns.

**SPOKE_NATIVE deposits use the same LZ-confirmed credit flow as BRIDGED deposits in Phase 1.** Both custody types wait for the LZ message confirmation (~30s-2min). The difference is that SPOKE_NATIVE tokens are never bridged to the hub by the Sweeper — they stay on the spoke permanently. (In a future phase with the solver fast-fill layer, BRIDGED deposits could be instant ~3s while SPOKE_NATIVE deposits would still wait for LZ confirmation, since the solver model requires fronting capital on the hub and being reimbursed via bridge — impossible for tokens that can't be bridged.)

---

## Module Breakdown

Phase 1 is broken into **10 modules**. Each module is independently reviewable, compiles/tests in isolation, and has its own verification checklist. Modules are grouped into the four sub-phases from the implementation plan (1A / 1B / 1C / 1D).

**Status legend:** each module is marked with one of:
- 🟢 **DONE** — code merged, tests passing, verification checklist complete
- 🟡 **IN PROGRESS** — actively being implemented
- ⚪ **NOT STARTED** — dependencies not yet met or not yet scheduled

**Current Phase 1 status (as of 2026-04-14):**

| Module | Status | Notes |
|---|---|---|
| M1 — BalanceLedger.sol core | 🟢 **DONE** | Landed 2026-04-09. 3-state model + on-chain collateral flag (`_usedAsCollateral`, `_flaggedAssets`, `_flaggedAt`) + `markCollateral`/`unmarkCollateral` + `CollateralFlagSet` event (5 params: `writer, user, asset, used, flaggedAt`). Storage gap 45→42, frozen at 49 slots. 240/240 tests passing. See `collateral-loophole-fix-plan.md` P1a Completion Record for full file list and deviations. |
| M1b — IRiskModule + RiskModuleStub + CollateralManager | 🟢 **DONE** | Landed 2026-04-09. `IRiskModule.sol`, `RiskModuleStub.sol` (fail-closed: `canUnflag` unconditionally `false`), `ICollateralManager.sol`, `CollateralManagerStorage.sol`, `CollateralManager.sol` (`OwnableUpgradeable + onlyOperator`, NOT `AccessControlUpgradeable`), `DeployCollateralStack.s.sol`. 36 new tests. `MAX_FLAG_LOCK = 30 days` ceiling added. See `collateral-loophole-fix-plan.md` P1a Completion Record for deviations from original spec. |
| M2 — Centuari.sol migration off Treasury | 🟢 **DONE** | Landed 2026-04-10. All balance ops migrated from Treasury to BalanceLedger (`debit`/`credit`). `_balanceLedger` slot added to `CentuariStorage.sol`. Auto-flag at settlement via `markCollateral(borrower, loanToken)` in `settleMatch()` (`Centuari.sol:179`). Auto-unflag loop in `repay()` clears all flagged assets when `_activeDebtCount[borrower] == 0` (`Centuari.sol:277-281`, bypasses 24h flag-lock). Zero Treasury references remain. Tests fully ported to BalanceLedger model with dedicated auto-flag/unflag coverage. **Fulfills `collateral-loophole-fix-plan.md` P1b-core for `Settlement`/`Centuari`.** ⚠️ Uses single `loanToken` as the implicit collateral — the multi-asset `MatchData.collateralAssets[]` plumbing is tracked as **P1b-ext** in `collateral-loophole-fix-plan.md` and is still pending, gated on P2 start. |
| M3 — Deployment scripts + testnet cutover + HubDepositor | 🟢 **DONE** | Landed 2026-04-10. HubDepositor.sol (IHubDepositor + HubDepositorStorage + HubDepositor) with deposit/payout via BalanceLedger credit/debit. DeployBalanceLedger.s.sol, DeployHubDepositor.s.sol, ConfigureBalanceLedger.s.sol (two-phase writer registration). run-all.sh rewritten to 14 steps — Treasury fully removed, BalanceLedger + HubDepositor + CollateralStack integrated. export-abi.sh updated (added BalanceLedger, HubDepositor, CollateralManager; removed Treasury). 270 tests passing. Local Anvil smoke test verified: deposit via HubDepositor correctly credits BalanceLedger.available. |
| M4 — WithdrawalRegistry + HubIntentSettler + SettlementLedger | 🟢 **DONE** | Landed 2026-04-12. WithdrawalRegistry (state machine + HF gate via `IRiskModule.canWithdraw` as the first action of `requestWithdrawal`, `WithdrawalRegistry.sol:110-112`) is **active in Phase 1**. HubIntentSettler and SettlementLedger are built and tested but **dormant** — their solver-facing functions (`fillFor`, `register`, `releaseToSolver`) are not used in Phase 1. `HubIntentSettler` will gain a new `confirmDeposit` function in M5 to handle LZ-confirmed cross-chain credits (the Phase 1 deposit path). 339 tests passing. **Fulfills `collateral-loophole-fix-plan.md` P1b-core `WithdrawalRegistry.canWithdraw` gate requirement.** |
| M5 — Spoke contracts + LayerZero + CCTP + Stargate + spoke-native custody | ⚪ NOT STARTED | **UNBLOCKED** — next priority. Depends on M4 (done). |
| ~~M6 — Solver Service~~ | ⏭️ **DEFERRED** | Deferred to a future phase. Solver fast-fill requires significant capital (20% of peak 24h deposit volume per spoke). Phase 1 uses LZ-confirmed credits instead (~30s-2min latency). See "Future: Solver Fast-Fill Layer" section. |
| M7 — Sweeper Bot (simplified) | ⚪ NOT STARTED | blocked on M5. **Simplified scope:** bridges escrowed tokens spoke → hub for custody + replenishes spoke withdrawal buffers. No solver reimbursement flow. |
| M8 — indexer-v3 from scratch | ⚪ NOT STARTED | **UNBLOCKED** — can start in parallel with M5. Depends on M3 (done). |
| M9 — backend-v2 + settlement-engine + matching-engine updates | ⚪ NOT STARTED | blocked on M8 |
| M10 — frontend-revamp cross-chain UI + collateral toggle | ⚪ NOT STARTED | blocked on M4/M5 + M9 |

Dependency chain (no module starts until its deps are merged + verified):

```
M1 (BalanceLedger core)
 └─ M2 (Centuari.sol migration)
     └─ M3 (Deploy scripts + testnet redeploy)
         ├─ M4 (WithdrawalRegistry + Hub cross-chain contracts)
         │   └─ M5 (SpokeDepositGateway + Spoke contracts + LayerZero wiring)
         │       └─ M7 (Sweeper Bot — simplified, no solver reimbursement)
         ├─ M8 (indexer-v3 from scratch)
         │   └─ M9 (backend-v2 + settlement-engine + matching-engine updates)
         │       └─ M10 (frontend-revamp cross-chain UI)
         [M6 (Solver Service) — DEFERRED to future phase]
```

After M3 is merged, M4 and M8 can be worked on in parallel (different trees). M9 depends on M8 being live with event schemas. M10 depends on M4/M5 (to know the deposit intent shape) and M9 (to know the API shape). M6 (Solver Service) is deferred — see "Future: Solver Fast-Fill Layer" section.

---

## Phase 1A — BalanceLedger + Centuari Migration

### Module 1: BalanceLedger.sol core 🟢 DONE

**Completed 2026-04-09.** The 3-balance-state portion landed with 31/31 tests, then the on-chain `usedAsCollateral` flag extension was added in the same session (triggered by the exit-loophole design review — see `collateral-loophole-fix-plan.md`). Final state: `markCollateral`/`unmarkCollateral` + `_usedAsCollateral` + `_flaggedAssets` (EnumerableSet) + `_flaggedAt` (uint64) + `CollateralFlagSet` event with **5 params** `(writer, user, asset, used, flaggedAt)` — note the event has 5 params, not 4 as originally specced; `writer` was added as the first indexed param. Storage gap shrank 45→42, frozen at 49 total slots. 240/240 tests passing across 8 suites. See `collateral-loophole-fix-plan.md` P1a Completion Record for the full file list and verification results.

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

**Event (updated to match actual 5-param implementation):**

```solidity
event CollateralFlagSet(
    address indexed writer,    // added in P1a — the authorized writer that triggered the flag change
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

### Module 1b: IRiskModule + RiskModuleStub + CollateralManager 🟢 DONE

**Completed 2026-04-09.** Three new contracts landed as part of the P1a collateral-loophole-fix work. See `collateral-loophole-fix-plan.md` P1a Completion Record for full file list, verification results, and deviations from original spec.

**Key deviations from original spec below (reality differs — update any downstream plans against these, not the original spec):**
1. `CollateralManager` uses `OwnableUpgradeable + onlyOperator` (matching `Settlement.sol` repo convention), **NOT** `AccessControlUpgradeable + OPERATOR_ROLE` as specced below. There is no `grantRole` — governance sets operator via `CollateralManager.setOperator(addr)`.
2. `RiskModuleStub.canUnflag` is **unconditionally `false`** — it does NOT check `totalDebt == 0` as specced below, because at P1a landing time `Centuari.sol` had no per-user debt aggregator. (M2 later added `_activeDebtCount`, but `RiskModuleStub` was not retrofitted to read it.) The only Phase 1 path to clear a flag is `Centuari.repay` auto-unflag (✅ landed in M2).
3. `MAX_FLAG_LOCK = 30 days` ceiling + `FlagLockTooLong` error added (defensive, not in original spec).
4. `ICollateralManager.sol` + `CollateralManagerStorage.sol` were added as separate files (matching repo's interface-first + storage-contract pattern).

**Original spec preserved below for reference:**

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

### Module 2: Centuari.sol migration off Treasury 🟢 DONE

**Completed 2026-04-10.** All balance operations migrated from Treasury to BalanceLedger. Auto-flag at settlement (`markCollateral` in `settleMatch()`), auto-unflag loop in `repay()` when `_activeDebtCount == 0` (bypasses 24h flag-lock). `_balanceLedger` slot added to `CentuariStorage`. Tests fully ported with dedicated auto-flag/unflag coverage. Zero Treasury references remain in Centuari.sol or Settlement.sol.

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

### Module 3: Deployment scripts + testnet cutover + HubDepositor 🟢 DONE

**Scope:** add deployment scripts for BalanceLedger + HubDepositor, update `run-all.sh` orchestration, redeploy full stack on Arbitrum Sepolia. Document the cutover. **Wipe of existing testnet balances is accepted per C8.**

**Addresses concerns:** C9 (Arbitrum hub-native deposit path — no LZ, no solver).

**HubDepositor.sol — hub-native direct deposit/withdrawal:**

- Minimal contract (or equivalent methods on Centuari.sol) that is the single entry point for users already on Arbitrum. Path 1 from Full Architecture §6.5.1.
- `deposit(asset, amount)` — `safeTransferFrom(msg.sender, this, amount)` then `balanceLedger.credit(msg.sender, asset, amount)` in the same transaction. No intent, no solver, no LayerZero. **Reverts with `UnsupportedAsset` if `asset` is not on the supported whitelist.**
- `payout(user, asset, amount)` — called by `WithdrawalRegistry` when the withdrawal target chain is Arbitrum itself. Releases tokens directly from the hub contract's custody. No LZ message. **Not gated by the whitelist** — owner can release any token in custody.
- `addSupportedAsset(asset)` / `removeSupportedAsset(asset)` — owner-only whitelist management. Emits `AssetAdded` / `AssetRemoved`. Only whitelisted assets can be deposited.
- `isSupportedAsset(asset)` — view to check whether an asset is on the whitelist.
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
- `smart-contract-revamp/script/ConfigureHubDepositor.s.sol` (new — register supported assets on HubDepositor)
- `smart-contract-revamp/bin/run-all.sh` (modify — add steps for BalanceLedger, HubDepositor, and ConfigureHubDepositor)
- `smart-contract-revamp/bin/export-abi.sh` (modify — export BalanceLedger + HubDepositor ABIs)
- `smart-contract-revamp/deployments/deploy-arbitrum-sepolia-latest.json` (regenerated output)

**Testnet-only shortcut:** add a `FORCE_ADMIN_WRITER_REGISTRATION` flag to BalanceLedger that allows instantly adding writers without the 48h wait. Must be disabled before mainnet. Guard with a hardcoded chainId check or a deployment-time constant.

**Verification:**

- `./bin/run-all.sh` deploys the full stack to Arbitrum Sepolia.
- `deployments/deploy-arbitrum-sepolia-latest.json` contains BalanceLedger proxy address.
- Verify `HubDepositor.isSupportedAsset(token)` returns `true` for all deployed mock tokens after ConfigureHubDepositor step.
- Verify `HubDepositor.deposit(unsupportedToken, amount)` reverts with `UnsupportedAsset`.
- Manually call `HubDepositor.deposit()` via cast with a supported token, confirm BalanceLedger available balance updated for the depositor.
- Manually place a lend + borrow match via the existing settlement flow, confirm balances flow through BalanceLedger, not Treasury.
- Export ABIs and verify they end up in `abi/` for downstream services.

---

## Phase 1B — Hub Cross-Chain Contracts

### Module 4: WithdrawalRegistry + HubIntentSettler + SettlementLedger 🟢 DONE

**Scope:** the three hub-side cross-chain contracts. Withdrawal state machine (active in Phase 1), plus solver intent settlement and reimbursement tracking (built but **dormant** — activated when the solver fast-fill layer is added in a future phase; see "Future: Solver Fast-Fill Layer" section).

**Addresses concerns:** C5 (deposit confirmation — `HubIntentSettler` will gain a `confirmDeposit` function in M5 for LZ-confirmed credits), C10 (events emitted here — `WithdrawalRequested`, `WithdrawalStateChanged`, `DepositConfirmed` — are tailed by the indexer and eagerly applied by services through `applyOnChainEffect`).

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

**HubIntentSettler — Phase 1 role (LZ-confirmed deposit credits):**

The M4 landing includes the solver-facing `fillFor` and `markNoFill` functions (built and tested), but these are **dormant in Phase 1**. The Phase 1 deposit credit path is a new `confirmDeposit` function added in M5:

- `confirmDeposit(depositId, user, asset, amount, sourceChainId)` — **added in M5.** Callable only by the LayerZero endpoint from a trusted `SpokeDepositGateway`. Verifies the LZ message origin, rejects replay by tracking used `depositId`s, credits `BalanceLedger.available[user] += amount`, marks the deposit as `CREDITED`, emits `DepositConfirmed(depositId, user, asset, amount, sourceChainId)`. For SPOKE_NATIVE tokens, also updates `ChainLiquidity`.
- `fillFor(...)` — **dormant in Phase 1.** Remains for future solver integration. Gated by `onlyOperator`.
- `markNoFill(...)` — **dormant in Phase 1.** Remains for future solver integration.
- No EIP-712 signing. No user-constructed intent. The spoke deposit event is the sole source of truth.

**SettlementLedger — dormant in Phase 1:**

Built and tested but not used in Phase 1 (no solver reimbursement flow). All functions remain for future solver activation:
- `register(orderId, solver, amount)` — called by HubIntentSettler on solver fill (future).
- `match(orderId, bridgedAmount)` — called by Sweeper Bot after bridge confirmation (future).
- Tracks per-orderId state: `REGISTERED → BRIDGED → REIMBURSED`.

See **"Future: Solver Fast-Fill Layer"** section for when and how to activate.

**Testing requirements:**

- WithdrawalRegistry: unit tests for every state transition; SLA timeout test with `vm.warp`.
- HubIntentSettler: test `fillFor` replay protection, `depositId` tracking, operator gate. (Solver-path tests are passing but dormant in Phase 1 — they validate the contract is ready for future activation.)
- SettlementLedger: test full register → match flow; test out-of-order matching; test match-before-register rejection. (Tests are passing but cover dormant functionality.)

**Verification:**

- `forge test --match-path 'test/cross-chain/*' -vv` passes.
- Deploy to Arbitrum Sepolia via `DeployCrossChainHub.s.sol`.

---

## Phase 1C — Spoke Chain Contracts

### Module 5: Spoke contracts + LayerZero + CCTP + Stargate + spoke-native custody ⭐ DONE

**Scope:** the three spoke-side contracts that live on the **four spoke chains only: Base, Ethereum, BNB, Polygon**. No spoke deployment on Arbitrum (hub uses `HubDepositor` from M3 per C9). Also adds LayerZero V2, Circle CCTP, and Stargate V2 dependencies to the Foundry project. Spoke contracts handle **two custody modes** per the token×chain matrix: BRIDGED tokens (escrowed temporarily, bridged to hub) and SPOKE_NATIVE tokens (held permanently, hub tracks accounting only). Additionally, hub contracts gain `ChainLiquidity` tracking for SPOKE_NATIVE tokens and a new receiver for spoke-native deposit confirmations.

**Addresses concerns:** C5 (spoke refund gating — `SpokeDepositGateway` built from scratch), C7 (DVN config — D7 now resolved: testnet 1-of-1 LayerZero Labs, mainnet 2-of-2 LayerZero Labs + Google Cloud), C11 (spoke-native custody and per-chain liquidity tracking).

**Files to create:**

- `smart-contract-revamp/lib/layerzero-v2/` (git submodule)
- `smart-contract-revamp/lib/cctp/` (git submodule for Circle's TokenMessenger interfaces)
- `smart-contract-revamp/lib/stargate-v2/` (git submodule for Stargate V2 pool interfaces)
- `smart-contract-revamp/remappings.txt` (add LZ + CCTP + Stargate paths)
- `smart-contract-revamp/config/token-chain-matrix.json` (new — single source of truth for token×chain routing)
- `smart-contract-revamp/src/core/cross-chain/spoke/SpokeVaultStable.sol`
- `smart-contract-revamp/src/core/cross-chain/spoke/SpokePayout.sol`
- `smart-contract-revamp/src/core/cross-chain/spoke/SpokeDepositGateway.sol` **(this is new — absent from feat branch)**
- `smart-contract-revamp/src/libraries/cross-chain/ChainLiquidityTracker.sol` (or integrated into WithdrawalRegistry storage)
- Matching interfaces + errors + events
- `smart-contract-revamp/test/cross-chain/spoke/*.t.sol`
- `smart-contract-revamp/script/DeployCrossChainSpoke.s.sol` — parameterized by target chainId
- `smart-contract-revamp/config/layerzero-dvn.json` — DVN stack configuration per pathway

**SpokeVaultStable (dual custody):**

- Holds both **temporary escrow** (BRIDGED tokens waiting for Sweeper) and **permanent custody** (SPOKE_NATIVE tokens that never leave the spoke).
- `sweepToHub(asset, amount, hubAddress)` — Sweeper calls. **Only for BRIDGED tokens.** Routes by token×chain matrix: CCTP burn/mint for USDC (Base/ETH/Polygon), Stargate V2 pool transfer for USDC on BNB and for USDT/WETH. Reverts with `CannotSweepSpokeNative()` for SPOKE_NATIVE tokens.
- `custodyBalance(asset) → uint256` — view returning the permanent SPOKE_NATIVE custody balance for an asset. Used by SpokePayout to verify sufficient liquidity before releasing.
- `HIGH_WATER_MARK` / `LOW_WATER_MARK` config — **only applies to BRIDGED tokens**. SPOKE_NATIVE token liquidity reflects organic deposit patterns and is not rebalanced.
- View functions for Sweeper monitoring (BRIDGED tokens only).

**SpokePayout (dual mode):**

- `release(user, asset, amount)` — callable only after `WithdrawalRegistry` authorization arrives via LayerZero.
- For **BRIDGED withdrawals:** releases from the spoke's BRIDGED buffer (replenished by Sweeper from hub). Queue mechanism if buffer insufficient (queues until Sweeper replenishes).
- For **SPOKE_NATIVE withdrawals:** releases from SpokeVaultStable's permanent custody. Must verify `SpokeVaultStable.custodyBalance(asset) >= amount`. No queue — if custody is insufficient, the withdrawal should have been rejected at the hub level via `ChainLiquidity` check.

**SpokeDepositGateway (dual mode, user-driven, no signing, no solver):**

- `deposit(asset, amount, hubRecipient)` — called directly by the user from their wallet. Pulls tokens via `safeTransferFrom`. Behavior depends on token×chain matrix:
  - **If BRIDGED (CCTP/STARGATE):** generates `depositId = keccak256(block.chainid, msg.sender, nonce)`, escrows tokens temporarily in SpokeDepositGateway, emits `DepositInitiated(depositId, user, asset, amount, hubRecipient)`, dispatches LayerZero message to hub carrying `(depositId, user, asset, amount, sourceChainId)`. Hub receives the LZ message and credits `BalanceLedger.available` immediately (~30s-2min). Sweeper bridges escrowed tokens spoke → hub in the background for custody (5-20 min). **No solver involved.**
  - **If SPOKE_NATIVE:** transfers tokens to SpokeVaultStable permanent custody, emits `SpokeNativeDeposit(user, asset, amount, sourceChainId)`, dispatches LayerZero message to hub to credit BalanceLedger + update ChainLiquidity. User waits for LZ message confirmation (~30s-2min). No bridge. No escrow.
- `permitAndDeposit(asset, amount, hubRecipient, deadline, v, r, s)` — one-click variant for EIP-2612 tokens. Works for both BRIDGED and SPOKE_NATIVE paths.
- `refund(depositId)` — **user-callable. BRIDGED deposits only.** Gated on a timeout: `block.timestamp >= depositTimestamp + REFUND_WINDOW` (e.g., 30 min). Before releasing escrow, the refund path must verify that no hub-side credit was issued for this `depositId` — either via a hub-side LZ message confirming no credit, or a timeout-based approach with replay protection. SPOKE_NATIVE deposits have no refund path — tokens go directly to SpokeVaultStable permanent custody and are confirmed via LZ message.

**Hub contract changes for cross-chain deposit credits (both BRIDGED and SPOKE_NATIVE):**

- **`ChainLiquidity` tracking** — new storage mapping `ChainLiquidity[token][chainId] → uint256` tracking physical token balances per chain. Could live on WithdrawalRegistry (simplest — co-located with withdrawal checks) or in a separate `ChainLiquidityTracker.sol`. Updated on: SPOKE_NATIVE deposit confirmation (+), SPOKE_NATIVE withdrawal authorization (−).
- **New hub LZ receiver for ALL cross-chain deposits** — `HubIntentSettler.confirmDeposit(depositId, user, asset, amount, sourceChainId)`, callable only by the LayerZero endpoint from a trusted `SpokeDepositGateway`. Credits `BalanceLedger.credit(user, asset, amount)`, marks the `depositId` as `CREDITED`, and emits `DepositConfirmed(depositId, user, asset, amount, sourceChainId)`. For SPOKE_NATIVE tokens, also increments `ChainLiquidity[asset][sourceChainId] += amount`. This single function handles both BRIDGED and SPOKE_NATIVE deposit confirmations — the only difference is whether the Sweeper later bridges the tokens (BRIDGED) or they stay on the spoke permanently (SPOKE_NATIVE).
- **`WithdrawalRegistry.requestWithdrawal()` update** — for SPOKE_NATIVE tokens, additionally checks `ChainLiquidity[token][targetChain] >= amount` and reverts with `InsufficientChainLiquidity(targetChain, available, requested)` if not enough. Decrements `ChainLiquidity` atomically with the BalanceLedger debit.
- **`HubIntentSettler.fillFor()`** — **dormant in Phase 1.** Remains in the contract for future solver integration (see "Future: Solver Fast-Fill Layer" section) but is not called by any Phase 1 flow. The `onlyOperator` gate prevents unauthorized use.

**LayerZero DVN configuration (D7 RESOLVED):**

LayerZero V2 is used for **message passing only** (proof-of-deposit, withdrawal authorization, spoke-native deposit confirmation, refund proofs). It never moves tokens.

- **Testnet:** 1-of-1 DVN (LayerZero Labs DVN only) across all four spoke ↔ hub pathways. Acceptable because testnet has no real money at risk.
- **Mainnet:** 2-of-2 DVN (LayerZero Labs + Google Cloud) across all pathways. Both DVNs are confirmed available on all five target chains (Arbitrum, Base, Ethereum, BNB, Polygon).
- 3-of-3 liquidation pathway remains a Phase 2 follow-up (no liquidation engine in Phase 1).
- Create a `ConfigureDVN.s.sol` script that calls `OAppOptionsType3.setEnforcedOptions` + `EndpointV2.setConfig` per pathway.
- Hard-code the config values in `config/layerzero-dvn.json` keyed by `{hubChainId, spokeChainId}`.
- **Test:** deploy on Arbitrum Sepolia + each spoke, send a dummy LZ message per pathway, confirm it arrives.

**Bridge routing (D5 RESOLVED — three protocols, distinct roles):**

| Protocol | Role | Tokens | Fee |
|---|---|---|---|
| **LayerZero V2** | Message passing only | Never moves tokens | Gas only |
| **CCTP v2** | USDC bridging (burn/mint) | USDC on Base/ETH/Polygon | Free |
| **Stargate V2** | Token bridging (pool-based) | USDC on BNB, USDT, WETH, WBTC | ~0.06% |

Routing per token per chain is defined in the Token × Chain Matrix (see "Token Classification & Cross-Chain Custody Architecture" section). The machine-readable source of truth is `config/token-chain-matrix.json`, consumed by M5, M7, M8, M9, and M10.

**Testing requirements:**

- Fork tests against Arbitrum Sepolia + Base Sepolia where possible.
- SpokeDepositGateway: test BRIDGED deposit — tokens escrowed, LZ message dispatched, hub credits BalanceLedger on LZ receipt.
- SpokeDepositGateway: test refund — refund after timeout succeeds if no hub credit; refund after hub credit reverts (replay protection).
- SpokeDepositGateway: test SPOKE_NATIVE deposit — token goes to SpokeVaultStable permanent custody, LZ message dispatched, hub credits BalanceLedger + ChainLiquidity.
- SpokeVaultStable: test `sweepToHub` reverts for SPOKE_NATIVE tokens.
- SpokePayout: test SPOKE_NATIVE withdrawal releases from custody, verify balance check.
- Hub ChainLiquidity: test increment on spoke-native deposit, decrement on withdrawal, revert on insufficient liquidity.
- CCTP mock + Stargate mock + LZ mock for unit tests.

**Verification:**

- `forge test` passes locally with CCTP + Stargate + LZ mocks.
- Spoke contracts deploy to Base Sepolia via `DeployCrossChainSpoke.s.sol --chainId 84532`.
- LayerZero DVN config committed to chain, verified via block explorer.
- End-to-end manual test (BRIDGED): deposit USDC to `SpokeDepositGateway` on Base → LZ message arrives on Arbitrum → `HubIntentSettler.confirmDeposit` credits BalanceLedger → Sweeper bridges escrowed USDC to Arbitrum via CCTP. User sees balance in ~30s-2min.
- End-to-end manual test (SPOKE_NATIVE): deposit XSGD to `SpokeDepositGateway` on Base → token stays on Base in SpokeVaultStable custody → LZ message credits BalanceLedger on Arbitrum + ChainLiquidity updated. User sees balance in ~30s-2min.

**M5 implementation deviations (recorded for audit):**

1. **Refund semantics**: doc left open "hub LZ confirmation vs timeout-based". Implementation chose **timeout-based**: `REFUND_WINDOW = 30 min`, combined with hub-side `_depositStatuses[depositId] == CREDITED` idempotency check. Simpler and race-free.
2. **Chain liquidity storage**: placed inside `WithdrawalRegistryStorage` (as `_chainLiquidity` mapping) rather than a standalone `ChainLiquidityTracker.sol` — fewer proxies, same invariant. Reversible if M9 needs cross-contract reads.
3. **Trusted remote config**: added as owner-only `setTrustedRemote(eid, peer)` on `HubIntentSettler` rather than via a separate registry.
4. **No OAppSender/OAppReceiver inheritance**: the LZ V2 package only ships non-upgradeable variants (immutable endpoint). All spoke and hub contracts store `_endpoint` + `_peers` in their `*Storage` contracts and call the endpoint directly. PR 5 can migrate to `@layerzerolabs/oapp-evm-upgradeable` as a follow-up if needed.
5. **SpokePayout bridged queue**: uses a per-user per-asset array (`_pendingPayouts[user][asset][]`) with FIFO flush. No cap on queue depth — the Sweeper Bot is expected to replenish the buffer before the queue grows large.

**M5 final test count:** 438 tests passing (339 hub baseline + 99 M5 additions across 6 new test files).

**M5 PR breakdown:**
- PR 1: Dependencies + config + mocks + storage scaffolding (339→339 tests, no behavior change)
- PR 2: SpokeVaultStable + SpokeDepositGateway (339→396 tests)
- PR 3: HubIntentSettler.confirmDeposit + WithdrawalRegistry capacity gate (396→424 tests)
- PR 4: SpokePayout + WithdrawalRegistry LZ dispatch + integration tests (424→438 tests)
- PR 5: Deploy scripts + ABI export + docs (no test changes)

---

## Phase 1D — Off-Chain Services

### ~~Module 6: Solver Service~~ ⏭️ DEFERRED

**Status:** deferred to a future phase. See **"Future: Solver Fast-Fill Layer"** section at the end of this document.

**Why deferred:** the solver requires significant upfront capital (Full Architecture §2.7: 20% of peak 24h deposit volume per spoke × 5 spokes) that is impractical for a startup at launch. Phase 1 uses LZ-confirmed credits instead (~30s-2min latency vs ~3s with solver). The on-chain contracts (`HubIntentSettler.fillFor`, `SettlementLedger`) are already built and tested in M4 and remain dormant until activated.

**What this removes from Phase 1 scope:**
- `solver-service/` directory and all its files
- `solver-service` entry in `docker-compose.yml`
- Solver capital management, monitoring, and alerting
- `HubIntentSettler.markNoFill()` keeper flow (refund path simplified to timeout-based)

---

### Module 7: Sweeper Bot (simplified — no solver reimbursement) ⚪ NOT STARTED

**Scope:** new service that bridges escrowed tokens from spoke to hub after LZ-confirmed deposits, and from hub to spoke to replenish withdrawal buffers. **No solver reimbursement flow** — the Sweeper is a pure bridge bot in Phase 1.

**Addresses concerns:** C10 (sweeper eagerly applies DB mutations after its bridge txs via the shared helper from Module 8; indexer tails as safety net).

**Files to create:**

- `sweeper-bot/` — new top-level directory
- `sweeper-bot/package.json`
- `sweeper-bot/src/index.ts`
- `sweeper-bot/src/inbound-flow.ts` — monitors `DepositInitiated` events on spoke `SpokeDepositGateway` contracts for BRIDGED tokens. After the hub confirms the deposit via LZ (BalanceLedger already credited), the Sweeper calls `SpokeVaultStable.sweepToHub(asset, amount, hubAddress)` to bridge the escrowed tokens from spoke → hub via CCTP or Stargate. This is a background custody reconciliation operation — it does NOT affect user-visible balance (that was already credited by `confirmDeposit`). **After the bridge tx lands**, imports `applyOnChainEffect` from the shared helper (Module 8) and eagerly updates `cross_chain_deposit.state = BRIDGED`, stamps idempotency columns.
- `sweeper-bot/src/outbound-flow.ts` — Sweeper Flow B (hub → spoke to replenish withdrawal buffers for BRIDGED tokens)
- `sweeper-bot/src/bridge-client.ts` — wraps Circle CCTP + Stargate V2 calls. Routes by CustodyType per token per chain (reads `token-chain-matrix.json`). CCTP for USDC on Base/ETH/Polygon. Stargate for USDT/WETH/WBTC and USDC-on-BNB. LayerZero is NOT used for token movement — only for message passing in other modules. SPOKE_NATIVE tokens are never bridged by the Sweeper — they stay on their spoke permanently.
- `sweeper-bot/src/water-marks.ts` — `HIGH_WATER_MARK = 3x rolling 24h`, `LOW_WATER_MARK = 1x rolling 24h` per config. **Water marks only apply to BRIDGED tokens.** SPOKE_NATIVE tokens have no buffer management — their liquidity distribution reflects organic deposit patterns and is not rebalanced.
- `sweeper-bot/Dockerfile`
- `docker-compose.yml` (modify — add sweeper-bot)

**What is NOT in Phase 1 Sweeper (deferred with solver):**
- `ledger-matcher.ts` / `SettlementLedger.match()` — no solver reimbursement tracking
- Solver capital restoration — no solver to reimburse

**Monitoring:**

- Prometheus: `sweeper_pending_bridges`, `sweeper_bridge_latency_ms`, `sweeper_last_event_age_s`.
- Alert if `sweeper_last_event_age_s > 1800` (30 min = stale; backup Sweeper should take over).

**Backup strategy:** primary is the Centuari-run Sweeper. Gelato-based backup is a Phase 2+ concern per architecture. For Phase 1 testnet, a single Sweeper is acceptable; document the SPOF.

**Verification:**

- After a cross-chain deposit is LZ-confirmed on the hub, confirm Sweeper detects the escrowed tokens on the spoke, bridges via CCTP/Stargate, and tokens arrive on hub.
- Manually drain a spoke's `SpokeVaultStable` below `LOW_WATER_MARK`, confirm Sweeper replenishes from hub.

---

### Module 8: indexer-v3 from scratch (custom, no framework) ⚪ NOT STARTED

**Scope:** brand-new custom Node.js/TypeScript indexer. **Ponder explicitly rejected** — the previous attempt hit dead ends because Ponder's enforced schema model and handler abstraction did not fit multi-chain state rollups (e.g., reflecting a single user's balance from events on hub + all four spokes in one `UserBalance` row). We build our own with the same stack conventions as `backend-v2`: TypeScript, pnpm, Viem, raw `pg`, Biome. Docker-compose already expects `indexer-v3/` at port 42069; directory does not exist yet.

**Addresses concerns:** C6 (custom indexer, not Ponder), C10 (indexer is the safety-net writer; eager-path services also write through the shared idempotency helper).

**Architecture:**

- **Event watcher layer:** one `ChainWatcher` per chain (hub + 4 spokes = 5 watchers). Each uses Viem `createPublicClient` with a WebSocket transport (falling back to HTTP polling) and `watchEvent` / `getLogs` per contract on that chain. A `BlockCursor` table per chain tracks the last fully-processed block; on restart, the watcher replays from `lastBlock + 1` to current.
- **Reorg handling:** store each event with `blockNumber`, `blockHash`, `logIndex`. On every new head, compare the chain's recent N-block hashes against stored hashes; if a divergence is found, delete rows with block > fork-point and replay. N = 12 for hub (Arbitrum finality), N = 64 for Ethereum Sepolia, N = 32 for others. Configurable per chain.
- **Event processors:** each contract has a processor module that takes a decoded event and writes domain entities transactionally using `pg` client `BEGIN/COMMIT`. All writes for a single block on a single chain happen in one transaction so the block cursor + entity updates are atomic.
- **REST API layer:** lightweight Fastify server (Fastify chosen over Hono for node-native ergonomics and because backend-v2 already uses Fastify-style plugins under NestJS). Exposes the endpoints the backend + matching engine + frontend need.
- **No GraphQL.** REST only. Matches backend-v2 conventions and avoids a second query language.

**Files to create:**

- `indexer-v3/` — new top-level directory
- `indexer-v3/package.json` — `viem`, `pg`, `fastify`, `zod`, `pino`, `dotenv`; dev: `tsx`, `@biomejs/biome`, `typescript`
- `indexer-v3/tsconfig.json` — ES2022, strict, nodenext
- `indexer-v3/biome.json` — copy from backend-v2
- `indexer-v3/.env.example`
- `indexer-v3/Dockerfile` — multi-stage, Node 22-alpine
- `indexer-v3/migrations/001_init.sql` — raw Postgres schema (see entities below)
- `indexer-v3/migrations/runner.ts` — simple sequential `.sql` migration runner (pattern used by matching-engine already)
- `indexer-v3/src/index.ts` — entry point: loads config, runs migrations, starts all ChainWatchers, starts Fastify
- `indexer-v3/src/config.ts` — Zod-validated env schema: `DATABASE_URL`, per-chain RPC URLs, contract addresses per chain, start block per chain
- `indexer-v3/src/db/client.ts` — shared `pg.Pool`
- `indexer-v3/src/db/queries.ts` — typed query helpers for each entity
- `indexer-v3/src/chain/chain-watcher.ts` — generic ChainWatcher class, takes a chain config + list of (contract, processor) pairs
- `indexer-v3/src/chain/reorg-detector.ts` — block-hash comparison logic
- `indexer-v3/src/shared/apply-on-chain-effect.ts` — **shared idempotency helper (C10).** Exported for re-use by backend-v2, settlement-engine, and sweeper-bot. Takes `(txHash, expectedEventSelector, expectedArgsPredicate, mutationFn)`. Fetches the receipt via Viem, verifies status and event, and applies the mutation inside a transaction that also stamps `applied_by_tx_hash`, `applied_by_log_index`, `applied_by_block_hash`, `applied_by_block_number` on the affected row. Skips the write if a row is already stamped with the same tx hash — idempotent across the eager path and the indexer tail.
- `indexer-v3/src/processors/balance-ledger.processor.ts` — handles `Credited` / `Debited` → updates `user_balance.available`, and `CollateralFlagSet(user, asset, used, flaggedAt)` → updates `user_balance.used_as_collateral` + `user_balance.flagged_at` with the C10 idempotency stamps. The indexer is the authoritative read path for both the balance and the flag.
- `indexer-v3/src/processors/centuari.processor.ts` — handles Order / Match / Repay / Bond mint events. When `Centuari.repay()` triggers the auto-unflag loop, the resulting `CollateralFlagSet(..., used=false)` events come through `balance-ledger.processor.ts` above — this processor does not need to touch the flag column directly.
- `indexer-v3/src/processors/hub-depositor.processor.ts` — handles `Deposit` / `Payout` events on Arbitrum
- `indexer-v3/src/processors/hub-intent-settler.processor.ts` — handles `DepositConfirmed` events (LZ-confirmed cross-chain deposit credits). The solver-related events (`SolverFillRegistered`) are dormant in Phase 1 — processor should still decode them gracefully for forward compatibility but no solver fills will occur.
- `indexer-v3/src/processors/withdrawal-registry.processor.ts` — handles state transitions on `WithdrawalRequest`
- `indexer-v3/src/processors/settlement-ledger.processor.ts` — **dormant in Phase 1** (no solver reimbursement flow). Keep the processor stub for forward compatibility but it will not receive events.
- `indexer-v3/src/processors/spoke-deposit-gateway.processor.ts` — handles `DepositInitiated` events on spoke chains, seeds `cross_chain_deposit` rows
- `indexer-v3/src/processors/spoke-vault.processor.ts` — handles spoke custody events
- `indexer-v3/src/api/server.ts` — Fastify bootstrap
- `indexer-v3/src/api/routes/balance.ts` — `GET /balance/:user` + `GET /balance/:user/:asset`
- `indexer-v3/src/api/routes/collateral.ts` — **read-only** `GET /collateral/:user/:asset` returning `{ used: boolean, flaggedAt: number | null, unlocksAt: number | null }`. Flag writes happen on-chain via `CollateralFlagSet` events and flow through `balance-ledger.processor.ts` — there is **no internal write endpoint**. The old `PUT /internal/collateral/:user/:asset` from the earlier draft is removed along with the backend module that called it (see Module 9).
- `indexer-v3/src/api/routes/withdrawals.ts` — `GET /withdrawals/:user`
- `indexer-v3/src/api/routes/deposits.ts` — `GET /deposits/:user` + `GET /deposits/:depositId` (cross-chain deposit tracking)
- `indexer-v3/src/api/routes/portfolio.ts` — `GET /portfolio/:user` (aggregates balance + open withdrawals + in-flight cross-chain deposits in one call for frontend)
- `indexer-v3/src/api/routes/health.ts` — `GET /health` reports per-chain cursor lag
- `indexer-v3/src/abi/` — generated TypeScript ABI constants imported from `smart-contract-revamp/abi/` via a small `copy-abi.ts` script run on build

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
-- indexer-v3 stamps them on the auto paths.

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

CREATE TABLE cross_chain_deposit (
  deposit_id BYTEA PRIMARY KEY,
  user_address BYTEA NOT NULL,
  source_chain BIGINT NOT NULL,
  asset BYTEA NOT NULL,
  amount NUMERIC(78,0) NOT NULL,
  custody_type TEXT NOT NULL,    -- BRIDGED|SPOKE_NATIVE
  state TEXT NOT NULL,           -- INITIATED|CREDITED|BRIDGED|REFUNDED
  initiated_at TIMESTAMPTZ NOT NULL,
  credited_at TIMESTAMPTZ,      -- when hub confirmed via LZ message
  bridged_at TIMESTAMPTZ,       -- when Sweeper bridged tokens to hub (BRIDGED only)
  -- C10 idempotency stamps for the LAST state-transition tx
  applied_by_tx_hash BYTEA,
  applied_by_log_index INT,
  applied_by_block_hash BYTEA,
  applied_by_block_number BIGINT
);
CREATE INDEX ON cross_chain_deposit (user_address, initiated_at DESC);
-- Note: no `solver` column — solver is deferred to a future phase.
-- When solver is added, this table gains `solver BYTEA` + `filled_at TIMESTAMPTZ`
-- and the state machine adds FILLED between INITIATED and CREDITED.

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
- Trigger a cross-chain deposit on Base Sepolia's `SpokeDepositGateway` → `GET /deposits/<depositId>` shows the deposit moving `INITIATED → CREDITED → BRIDGED`.

---

### Module 9: backend-v2 + settlement-engine + matching-engine updates ⚪ NOT STARTED

**Scope:** update existing services to read from indexer-v3 + interact with new contracts.

**Addresses concerns:** C3 (matching engine reads BalanceLedger for validation), C10 (every service that submits an on-chain tx eagerly applies the DB mutation through the shared helper from Module 8; indexer tails the same events as the safety net).

**backend-v2 changes:**

- `backend-v2/src/deposit/` — no signing, no intent forwarding. The frontend drives the deposit tx directly against `HubDepositor` (Arbitrum) or `SpokeDepositGateway` (spokes), then POSTs the resulting `txHash + sourceChainId` back to `POST /deposit/verify`. The backend fetches the receipt via Viem, calls the shared `applyOnChainEffect` helper to verify the expected event (`HubDepositor.Deposited` or `SpokeDepositGateway.DepositInitiated`), and eagerly applies the resulting DB mutation (`user_balance.available += amount` for hub-direct, or `deposit_event` row + `cross_chain_deposit` seed for spoke). Returns the updated state to the frontend so the UI reflects it without waiting on the indexer. Indexer tails the same events as the safety net per C10. `GET /deposit/targets` returns the supported source-chain metadata. `GET /deposit/:depositId` reads the canonical row for progress polling. The existing `POST /deposit` Treasury-writing endpoint is removed. For cross-chain deposits, the hub-side BalanceLedger credit happens automatically when the LZ message arrives — no solver or backend intervention needed for the credit itself.
- `backend-v2/src/withdraw/` — replace `Treasury.withdraw` call path. New flow: backend calls `Centuari.requestWithdrawal(user, asset, amount, targetChain)` which hits `WithdrawalRegistry`, then eagerly applies the PENDING-state row via `applyOnChainEffect`. Subsequent state transitions (PROCESSING on LZ send, COMPLETED on LZ ack, FAILED on timeout) are applied the same way when the backend/settlement-engine submits each follow-up tx. Indexer tails as safety net per C10.
- `backend-v2/src/portfolio/` — replace Treasury balance queries with indexer-v3 REST calls. Surface the 3 sub-states (`available`, `inOrders`, `inYieldRouter`) plus the per-asset `usedAsCollateral` flag in the portfolio response shape.
- `backend-v2/src/collateral/` — **new module, on-chain-backed.** Single endpoint `POST /collateral/unflag { asset }` gated on Privy JWT. There is **no flag endpoint** — flagging happens implicitly at borrow-match settlement time (see matching-engine/settlement-engine in Module 9 and Settlement.sol auto-flag loop in Module 2). The unflag path:
  1. Reads the user's current flag state + `flagged_at` from indexer-v3 and rejects with HTTP 400 `NotFlagged` if the asset is not flagged.
  2. Rejects with HTTP 409 `FlagLockActive { unlocksAt }` if `now < flagged_at + 24h`.
  3. Submits `CollateralManager.unflagFor(user, asset)` via the protocol settlement key using the shared Viem signer.
  4. On success, eagerly applies the DB mutation through `applyOnChainEffect` (C10): writes `used_as_collateral = false`, `flagged_at = NULL`, stamps `applied_by_*` with the tx/log data. Returns the updated row.
  5. On `CollateralManager` reverts (`FlagLockActive`, `WouldMakeUnhealthy`, `NotFlagged`), maps the custom error to an HTTP 4xx with the decoded reason and does not mutate the DB.
- **Backend rate limit:** 5 `POST /collateral/unflag` calls per user per 24h via Redis counter. Belt-and-suspenders against settlement-key nonce burn across many assets; the on-chain 24h lock already caps throughput per asset.
- **Borrow-order DTO** (`backend-v2/src/orders/`): the borrow POST body gains `collateralAssets: string[]`. Backend validates the array is non-empty and that every listed asset has a positive `available` balance in indexer-v3 before publishing to NATS. The matching engine forwards it unchanged; the settlement engine encodes it per borrower in the `Settlement.settle()` call so the on-chain auto-flag loop can run. See Module 9 matching-engine and Module 2 Settlement changes.
- `backend-v2/src/chain-indexer/` — deprecate; point consumers at indexer-v3 instead.
- `backend-v2/src/core/viem/` — add new contract ABIs.
- `backend-v2/src/config/token-chain-matrix.ts` — imports from `token-chain-matrix.json`. Used by deposit validation (reject deposits for tokens not available on the source chain), withdrawal validation (reject withdrawals to chains where the token is not available or has insufficient liquidity), and portfolio display.
- **Withdrawal validation for SPOKE_NATIVE tokens:** backend additionally checks `ChainLiquidity[token][targetChain] >= amount` via indexer-v3 before submitting the on-chain tx. Rejects with HTTP 400 `InsufficientChainLiquidity { chain, available, requested }` if the target chain does not have enough physical tokens.
- **Deposit handling for SPOKE_NATIVE tokens:** when verifying a spoke deposit for a SPOKE_NATIVE token via `POST /deposit/verify`, the backend eagerly updates `ChainLiquidity` alongside the `BalanceLedger` credit through `applyOnChainEffect`.

**settlement-engine changes:**

- `settlement-engine/src/settlement/smartContract.ts` — no Treasury references today per exploration, so minimal change. But: the Settlement.sol contract itself is not changed in Phase 1 (that's Phase 3A's CentuariEndpoint). So settlement-engine's interaction with Settlement.sol is unchanged. Only the post-settlement event indexing moves to indexer-v3.
- Event consumers pointed at indexer-v3 instead of direct chain polling.
- **Auto-flag at match settlement.** `settlement-engine/src/settlement/smartContract.ts` passes `collateralAssets[]` per borrower into the updated `Settlement.settle()` ABI so the on-chain auto-flag loop (Module 2) marks each asset atomically with debt creation. No separate collateral worker, no standalone flag endpoint on the settlement key — the flag write is free-riding on a settlement tx that would happen regardless.

**matching-engine changes:**

- Add `matching-engine/src/services/balance-ledger-client.ts` — Viem client reading `BalanceLedger.getAvailable(user, asset)` with 1-block TTL cache.
- `matching-engine/src/core/matching-engine.ts` — call the client at order validation time. Reject if available < order amount. Document this is a soft check (final enforcement is at settlement per C1).
- `matching-engine/src/types/order.ts` — add `collateralAssets: string[]` to the borrow order schema (non-empty). The engine does not re-validate holdings (backend already did it at DTO validation time); it forwards the array unchanged in the match payload pushed to the Redis `settlement:matches` stream so the settlement engine can encode it into the on-chain `Settlement.settle()` call.
- Update Jest tests that previously mocked Treasury to mock BalanceLedgerClient instead.

**Testing requirements:**

- Backend: integration tests that hit a local indexer-v3 + deployed testnet contracts.
- Matching engine: unit tests with mocked BalanceLedgerClient covering "available < order amount" rejection.

**Verification:**

- Full end-to-end: `POST /deposit` with `sourceChain: arbitrum-sepolia` → Centuari.deposit → BalanceLedger.credit → indexer-v3 picks up event → `GET /portfolio/:user` returns new balance.
- Place a lend order exceeding available balance → matching engine rejects.

---

### Module 10: frontend-revamp cross-chain deposit/withdraw UI + collateral flow ⚪ NOT STARTED

**Scope:** new deposit/withdraw screens supporting the cross-chain flow + balance display showing the 3 sub-states + a collateral multi-select on the borrow form + a read-only collateral badge + countdown-gated unflag button on the portfolio.

**Files to modify:**

- `frontend-revamp/src/app/(app)/portfolio/` — 3-bucket balance display. For Phase 1, only `available` is non-zero (the other two are forward-compat). Each row also shows: a **Collateral** badge when `used_as_collateral = true`, a countdown label ("Unlocks in 18h 42m") driven by `flagged_at + 24h`, and a **Remove as collateral** button that is disabled until the countdown hits zero.
- `frontend-revamp/src/components/centuari-borrow/` — borrow order form gains a **collateral asset multi-select** (checkbox list of the user's deposited assets, default all selected). On submit, shows a confirmation modal: *"These assets will be locked as collateral for at least 24 hours after the match settles. You will not be able to unflag them before then, even after partial repayment. Full repayment will release them immediately. Continue?"* — user must tick an ack box before the submit button enables. The selected assets are posted as `collateralAssets: string[]` on the borrow order body.
- `frontend-revamp/src/components/centuari-deposit/` — source-chain selector is **token-aware**, driven by the token×chain matrix. For each token, only shows chains where `CustodyType != —` (i.e., the token is available on that chain). Users see "Arbitrum (direct)" for hub-native, spoke chains for cross-chain. Arbitrum (direct) uses `HubDepositor.deposit()` — single tx, ~15s. All cross-chain deposits (both BRIDGED and SPOKE_NATIVE) use the LZ-confirmed credit flow — balance appears in **~30s-2min** after LayerZero message confirmation. For SPOKE_NATIVE deposits, a note explains "Token will remain on {chain} for custody."
- `frontend-revamp/src/components/centuari-withdraw/` — target-chain selector is **token-aware and liquidity-aware**. For BRIDGED tokens: shows all chains the bridge supports (hub has full liquidity). Arbitrum (direct) releases via `HubDepositor.payout()` — instant. Cross-chain BRIDGED withdrawals use CCTP or Stargate (~2-5 min). For SPOKE_NATIVE tokens: shows each chain with its available liquidity amount, greys out chains with 0 liquidity. Reads `ChainLiquidity` from indexer-v3 via `GET /liquidity/:token`.
- `frontend-revamp/src/hooks/use-deposit.ts` — single `useWriteContract` call. Arbitrum (direct) → `HubDepositor.deposit(asset, amount)`. Spokes → `SpokeDepositGateway.permitAndDeposit(...)` if EIP-2612, else `approve` + `deposit`. **No `signTypedData`, no intent construction.** Polls `GET /deposits/:depositId` for cross-chain progress (`INITIATED → CREDITED → BRIDGED`).
- `frontend-revamp/src/hooks/use-withdraw.ts` — withdrawal state tracking via indexer-v3 polling.
- `frontend-revamp/src/hooks/use-unflag-collateral.ts` — **new hook.** No wallet popup. Calls `POST /collateral/unflag { asset }` with the Privy JWT. Optimistic update on click; rolls back on error. Distinct error paths:
  - `FlagLockActive` (HTTP 409) → toast "Locked until {unlocksAt}", disables button until the countdown elapses.
  - `WouldMakeUnhealthy` (HTTP 400, Phase 1 stub) → toast "Repay in full to release this collateral".
  - `WouldMakeUnhealthy` (HTTP 400, Phase 2 real) → toast "Would drop health factor below 1".
  The hook is purely a backend call; the Phase 2 swap is invisible at the UI layer.
- `frontend-revamp/src/lib/portfolio-data.ts` — indexer-v3 API, returns the 3 sub-states + `usedAsCollateral` + `flaggedAt` per asset.
- `frontend-revamp/src/lib/chain-config.ts` — spoke chain configs + token×chain matrix. Exports `getDepositChains(token): ChainConfig[]` and `getWithdrawChains(token): ChainConfig[]` for the selectors. For SPOKE_NATIVE tokens, `getWithdrawChains` requires a live liquidity lookup from indexer-v3.
- `frontend-revamp/e2e/cross-chain-deposit.spec.ts` — Playwright end-to-end.
- `frontend-revamp/e2e/collateral-flow.spec.ts` — Playwright e2e: (a) place a borrow with `collateralAssets = [USDC]` → collateral badge appears on the portfolio row after settlement; (b) unflag button is disabled with a countdown until `flagged_at + 24h`; (c) direct API call to `POST /collateral/unflag` before 24h returns HTTP 409 `FlagLockActive`; (d) after 24h, unflag while still in debt returns HTTP 400 `WouldMakeUnhealthy` (Phase 1 stub); (e) full repay auto-clears the flag without waiting 24h.

**Verification:**

- `pnpm run test:e2e` passes the new cross-chain deposit test (uses local devnet with mocked LZ endpoint).
- Manual smoke test: deposit 100 USDC on Base Sepolia from the UI, see balance appear on Arbitrum portfolio within ~30s-2min (LZ message confirmation).

---

## Overall Phase 1 Verification (End-to-End)

After all modules merged (M1-M5, M7-M10; M6 deferred), the following manual verification must pass before Phase 1 is declared done. This is the "definition of done" for Phase 1.

1. Deposit 100 USDC on Base Sepolia via the frontend. Balance appears in `available` on Arbitrum within **~30s-2min** (LZ message confirmation). Indexer-v2 shows the deposit flow: `INITIATED → CREDITED → BRIDGED`. Final state: user's `available` = 100, escrowed tokens bridged to hub by Sweeper.
2. Place a lend order for 50 USDC at 8% APY, 30-day maturity. Matching engine accepts (available > order). Match against a borrower. Settlement batch submitted. Post-settlement: lender has CBT-USDC-YYYY-MM-01 tokens, borrower has 50 USDC in available + debt position in Centuari. BalanceLedger invariant holds.
3. Request withdrawal of 50 USDC to Base Sepolia. Frontend shows "estimated 5–20 min". WithdrawalRegistry enters PENDING → PROCESSING → COMPLETED. User receives USDC on Base Sepolia. BalanceLedger available decremented by 50.
4. Kill the matching engine mid-operation. Restart. Confirm it recovers from Redis + re-reads BalanceLedger; no orders lost, no double fills.
5. Kill the Sweeper mid-bridge. Restart. Confirm it picks up un-bridged deposits and retries the spoke → hub bridge.
6. Run the invariant test suite: total tokens locked in all contracts == sum of all BalanceLedger balances + all in-flight cross-chain deposits + all in-flight withdrawals + all outstanding CBT supply.

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
- **Solver Service / fast-fill layer** — deferred due to capital requirements (20% of peak 24h deposit volume per spoke). Phase 1 uses LZ-confirmed credits (~30s-2min) instead of solver fast-fill (~3s). On-chain contracts (`HubIntentSettler.fillFor`, `SettlementLedger`) are built and dormant — see **"Future: Solver Fast-Fill Layer"** section.
- **SettlementLedger solver reimbursement flow** — deferred with solver. Contract exists but is dormant.

Any pressure to pull these forward must be routed back through the architecture doc and this plan updated.

---

## Resolved Decisions (Locked in for Phase 1)

1. **Hub + spoke chains:** Hub = **Arbitrum Sepolia**. Spokes = **Base Sepolia, Ethereum Sepolia, BNB Testnet, Polygon Amoy**. Four spoke chains total. M5 deploys `SpokeVaultStable` / `SpokePayout` / `SpokeDepositGateway` to all four. M7 (Sweeper) must support all four spokes from day one.
2. **Solver deferred:** solver fast-fill layer is deferred to a future phase due to capital requirements. On-chain contracts (`HubIntentSettler.fillFor`, `SettlementLedger`) are built and dormant. See **"Future: Solver Fast-Fill Layer"** section.
3. **Spoke refund design:** **Timeout-based.** `SpokeDepositGateway.refund(depositId)` is callable after `REFUND_WINDOW` (e.g., 30 min) if the hub has not credited the deposit. Simpler than the original solver-dependent proof-of-non-fill design. Replay protection ensures no double-credit.
4. **Testnet cutover:** **Clean wipe + redeploy.** Existing Arbitrum Sepolia Treasury balances are discarded. Testers re-deposit via the faucet after redeploy. No migration script.

## Token Classification & Cross-Chain Custody Architecture

### Three-Protocol Stack

Centuari uses three cross-chain protocols, each with a distinct non-overlapping role:

1. **LayerZero V2** — message passing ONLY. Carries proof-of-deposit messages (spoke → hub), withdrawal authorization (hub → spoke), and refund proofs (hub → spoke). Never moves tokens. DVN config: 1-of-1 testnet (LayerZero Labs), 2-of-2 mainnet (LayerZero Labs + Google Cloud).

2. **CCTP v2** (Circle) — USDC token bridging via burn/mint. Free (no protocol fee). Available on Arbitrum, Base, Ethereum, Polygon. NOT available on BNB. Used for USDC only.

3. **Stargate V2** (LayerZero ecosystem) — Token bridging via liquidity pools. ~0.06% fee. Used for: USDC on BNB (where CCTP unavailable), USDT on all spokes, WETH on ETH/Base, WBTC on ETH. Delivers native tokens from destination pools.

### Two Custody Models

Tokens fall into one of two custody models based on whether a bridge can move them to the hub:

**BRIDGED (hub custody):** Token bridges to Arbitrum hub at deposit time. Hub holds a single consolidated pool. User can withdraw to any chain the bridge supports. This is the model for high-volume tokens (USDC, USDT, WETH on bridgeable chains, WBTC) where liquidity fragmentation would hurt UX.

**SPOKE_NATIVE (per-chain tracking):** Token stays on the spoke chain where it was deposited. Hub tracks only accounting (BalanceLedger credit/debit via LZ message) plus a per-chain liquidity map: `ChainLiquidity[token][chainId] → amount`. User can withdraw to any chain that currently has liquidity for that token. This model applies to tokens that either (a) have no Stargate/CCTP pool, or (b) don't exist on the hub chain at all.

Some tokens are HYBRID — bridgeable on certain chains, spoke-native on others (e.g., WETH is bridged from ETH/Base but spoke-native on BNB/Polygon where Stargate has no WETH pool).

### Per-Chain Liquidity Tracking (for SPOKE_NATIVE tokens)

The hub maintains a `ChainLiquidity[token][chainId]` mapping that tracks how many physical tokens sit on each chain. This enables cross-chain lending even for non-bridgeable tokens:

1. **Deposit:** User deposits 1000 XSGD on Base → XSGD stays on Base → Hub: `BalanceLedger.credit(user, XSGD, 1000)` + `ChainLiquidity[XSGD][Base] += 1000`
2. **Lend/Borrow:** Pure accounting on hub. ChainLiquidity unchanged (tokens don't move).
3. **Withdrawal:** User wants to withdraw 500 XSGD → system checks ChainLiquidity per chain → shows available chains + amounts → user picks a chain with sufficient liquidity → spoke releases tokens → `ChainLiquidity[XSGD][chosenChain] -= 500`

Frontend withdrawal UI for spoke-native tokens shows per-chain availability:

```
Withdraw XSGD — Amount: 500
  ✅ Base      (1000 available)
  ✅ Polygon   (200 available)
  ✅ Arbitrum   (300 available)
  ❌ BNB       (0 — no liquidity)
  ❌ Ethereum  (0 — token not available)
```

For BRIDGED tokens, the hub holds everything — all chains show the full amount (bridge on demand).

### Token × Chain Matrix

| Token | Arbitrum (Hub) | Base | Ethereum | BNB | Polygon |
|---|---|---|---|---|---|
| USDC | HUB_DIRECT | CCTP | CCTP | STARGATE | CCTP |
| USDT | HUB_DIRECT | STARGATE | STARGATE | STARGATE | STARGATE |
| WETH | HUB_DIRECT | STARGATE | STARGATE | SPOKE_NATIVE | SPOKE_NATIVE |
| WBTC | HUB_DIRECT | — | STARGATE | — | — |
| XSGD | SPOKE_NATIVE | SPOKE_NATIVE | — | — | SPOKE_NATIVE |
| IDRX | — | SPOKE_NATIVE | — | SPOKE_NATIVE | — |
| XAUT | — | — | SPOKE_NATIVE | — | — |
| SLVon | — | — | SPOKE_NATIVE | SPOKE_NATIVE | — |
| NVDAon | — | — | SPOKE_NATIVE | SPOKE_NATIVE | — |
| AAPLon | — | — | SPOKE_NATIVE | SPOKE_NATIVE | — |
| TLTon | — | — | SPOKE_NATIVE | SPOKE_NATIVE | — |

Legend: `HUB_DIRECT` = deposit/withdraw via HubDepositor (no bridge). `CCTP` = USDC burn/mint (free). `STARGATE` = pool-based bridge (~0.06%). `SPOKE_NATIVE` = token stays on spoke, per-chain tracking. `—` = token not available on this chain.

### CustodyType Enum

```solidity
enum CustodyType {
    HUB_DIRECT,    // Arbitrum-native, deposit/withdraw via HubDepositor
    CCTP,          // USDC burn/mint, free (Base/ETH/Polygon)
    STARGATE,      // Pool-based bridge, ~0.06% fee (USDT, WETH, WBTC, USDC-on-BNB)
    SPOKE_NATIVE   // Token stays on spoke, per-chain liquidity tracking
}
```

### Bridge Routing Config

All modules that need custody/routing info read from a single source of truth: `smart-contract-revamp/config/token-chain-matrix.json`. Consumers:
- **M5** — `SpokeVaultStable.sweepToHub()` routes CCTP vs Stargate; spoke contracts accept SPOKE_NATIVE deposits
- **M7** — `sweeper-bot/src/bridge-client.ts` wraps CCTP + Stargate calls per token per chain
- **M8** — `indexer-v3` processors tag events with custody type; track `ChainLiquidity` for SPOKE_NATIVE tokens
- **M9** — backend validates withdrawal target chain against token×chain matrix; rejects impossible routes
- **M10** — frontend deposit/withdraw chain selectors filtered by matrix; SPOKE_NATIVE withdrawals show per-chain liquidity

### Token Descriptions

| # | Token | Decimals | Description | Custody Notes |
|---|---|---|---|---|
| 1 | USDC | 6 | USD Coin (Circle) | Highest volume. CCTP where available, Stargate on BNB. |
| 2 | USDT | 6 | Tether USD | Stargate on all spokes. |
| 3 | WETH | 18 | Wrapped Ether | Stargate on ETH/Base/Arb. Spoke-native on BNB/Polygon (no Stargate pool). |
| 4 | WBTC | 8 | Wrapped Bitcoin | Stargate on ETH/Arb only. Not available on Base/BNB/Polygon. |
| 5 | XSGD | 6 | StraitsX Singapore Dollar | Spoke-native on Arb/Base/Polygon. Not on ETH/BNB. |
| 6 | IDRX | 6 | Indonesian Rupiah stablecoin | Spoke-native on Base/BNB only. Not on Arb/ETH/Polygon. |
| 7 | XAUT | 6 | Tether Gold | Spoke-native on ETH only. |
| 8 | SLVon | 18 | iShares Silver Trust (Ondo) | Spoke-native on ETH/BNB. |
| 9 | NVDAon | 18 | NVIDIA stock (Ondo) | Spoke-native on ETH/BNB. |
| 10 | AAPLon | 18 | Apple stock (Ondo) | Spoke-native on ETH/BNB. |
| 11 | TLTon | 18 | Treasury Bond ETF (Ondo) | Spoke-native on ETH/BNB. |

---

## Resolved Decisions (Formerly Open)

- **D5 — Bridge routing (RESOLVED):** CCTP v2 mainnet available on Arbitrum, Base, Ethereum, Polygon. NOT available on BNB. BNB uses Stargate for USDC. Non-USDC tokens (USDT, WETH, WBTC) use Stargate where pools exist. Tokens without any bridge use SPOKE_NATIVE custody with per-chain liquidity tracking. Full routing in "Token × Chain Matrix" section above.
- **D7 — DVN providers (RESOLVED):** Google Cloud DVN confirmed available on all five target chains (Arbitrum, Base, Ethereum, BNB, Polygon) for mainnet. Testnet: 1-of-1 (LayerZero Labs only). Mainnet: 2-of-2 (LayerZero Labs + Google Cloud).

## Still Open

_No open decisions remaining for Phase 1. D6 (solver bootstrap capital) is deferred with the solver._

---

## Future: Solver Fast-Fill Layer

> **This section is a reference for future implementation.** None of this is in Phase 1 scope. It documents what was deferred, why, and what to build when the time comes.

### What the solver adds

The solver is a **latency optimization** for cross-chain deposits. Instead of waiting ~30s-2min for the LZ message to confirm a deposit on the hub, the solver fronts the equivalent tokens on the hub immediately (~3s), and is reimbursed later when the Sweeper bridges the escrowed tokens from spoke → hub.

| | Phase 1 (no solver) | Future (with solver) |
|---|---|---|
| Cross-chain deposit latency | ~30s-2min (LZ confirmation) | ~3s (solver front-run) |
| Capital required | Zero | 20% of peak 24h deposit volume per spoke |
| Services to operate | Sweeper only | Solver Service + Sweeper with reimbursement |
| Complexity | Lower | Higher (capital management, reimbursement tracking) |

### Why it was deferred

The solver requires significant upfront capital: Full Architecture §2.7 specifies 20% of peak 24h deposit volume per spoke as hub-side Arbitrum balance. For 5 spokes with any non-trivial volume, this is meaningful capital that a startup with limited liquidity cannot commit at launch. The 30s-2min latency of LZ-confirmed credits is acceptable for a lending protocol where users deposit infrequently and trade against their balance.

### When to revisit

Consider adding the solver when:
- Cross-chain deposit volume exceeds a threshold where 30s-2min latency becomes a competitive disadvantage
- The protocol has sufficient capital or external solver partners willing to front liquidity
- User feedback indicates deposit latency is a pain point

### What's already built (dormant in Phase 1)

The on-chain infrastructure for the solver is complete and tested:

- **`HubIntentSettler.fillFor(depositId, user, asset, amount, sourceChainId)`** — solver calls this to front tokens on hub. Pulls tokens from solver, credits `BalanceLedger.available`, registers reimbursement with `SettlementLedger`. Currently gated by `onlyOperator` (M5 will replace with LZ proof verification).
- **`HubIntentSettler.markNoFill(depositId)`** — solver calls when it decides not to fill (cap exceeded, offline). Unblocks refund on spoke.
- **`SettlementLedger.register(depositId, solver, asset, amount)`** — records reimbursement obligation.
- **`SettlementLedger.match(depositId, bridgedAmount)`** — Sweeper calls after bridging escrowed tokens from spoke to hub. Releases reimbursement to solver.
- **`HubIntentSettler.releaseToSolver(solver, asset, amount)`** — called by `SettlementLedger` to transfer tokens to solver wallet.

All contracts have passing tests (339 total as of M4 landing).

### What to build when ready

1. **Solver Service (`solver-service/`)** — new Node.js/TypeScript service:
   - `deposit-watcher.ts` — subscribes to `DepositInitiated` events on all spoke chains
   - `deposit-validator.ts` — validates asset, amount caps, source chain
   - `filler.ts` — waits for LZ proof, calls `HubIntentSettler.fillFor`, eagerly applies DB mutations via `applyOnChainEffect`
   - `no-fill-keeper.ts` — calls `markNoFill` for unfilled deposits past timeout
   - `capital-manager.ts` — tracks solver balance, enforces per-spoke + per-fill caps
   - Capital bootstrap: start with $50k per-spoke cap, team-funded hot wallet
   - Monitoring: `solver_capital_available`, `solver_fill_success_count`, `solver_fill_latency_ms`
   - Alert if `solver_capital_available < 2 × MAX_FILL_AMOUNT_USD`

2. **Sweeper reimbursement flow** — extend `sweeper-bot/src/inbound-flow.ts`:
   - After bridging escrowed tokens from spoke → hub, call `SettlementLedger.match(depositId, bridgedAmount)`
   - Eagerly apply DB mutation: `cross_chain_deposit.state = SETTLED`, solver reimbursement bookkeeping

3. **DB schema changes** — add to `cross_chain_deposit` table:
   - `solver BYTEA` — solver address that filled
   - `filled_at TIMESTAMPTZ` — when solver filled
   - `reimbursed_at TIMESTAMPTZ` — when solver was reimbursed
   - State machine gains `FILLED` between `INITIATED` and `CREDITED`

4. **Indexer processors** — activate dormant `settlement-ledger.processor.ts`, update `hub-intent-settler.processor.ts` to handle `SolverFillRegistered` events

5. **Refund path** — switch from timeout-based to solver-aware proof-of-non-fill via `markNoFill`

### Solver reimbursement destination (pre-decided)

**Solver EOA.** `SettlementLedger.match()` releases reimbursement directly to the solver's wallet, not to a BalanceLedger entry. Keeps BalanceLedger clean of operational accounts.

