# Cross-Chain Launch Plan (Consolidated)

> **Status:** drafted 2026-05-14. **DEFERRED** — picks back up after hub-only launch ships. See [`hub-only-launch-plan.md`](./hub-only-launch-plan.md) for the active checklist.
>
> **Provenance:** consolidates 6 previously-scattered docs into one canonical reference. The original docs remain in place as deep references (each carries a top-of-doc pointer back here):
> - `phase-1-cross-chain-balance-ledger.md` — original master plan
> - `m8-burn-in-completion.md` — M8 handoff
> - `m8-burn-in-runbook.md` — Phase 0–G operator runbook
> - `collateral-loophole-fix-plan.md` — collateral lifecycle (hub-relevant; cross-referenced here)
> - `collateral-frontend-implementation.md` — collateral UI (hub-relevant; cross-referenced here)
> - `phase-a-settlement-engine-eager-writes.md` — eager-write pattern
>
> **Hub-only relevant content** (collateral lifecycle, order-lock lifecycle, eager-write pattern) was hub-applicable work decided during the Phase 1 cross-chain effort. It is referenced from §10 below but its operational checklists live in `hub-only-launch-plan.md`.

---

## 1. Context & Why Cross-Chain

Centuari migrates from a single-chain, deposit-at-order-time lending protocol (current staging) to a cross-chain, deposit-first, gasless-orders protocol. Phase 1 cross-chain delivers:

A user deposits USDC (or any supported token) on **Base, Ethereum, BNB, or Polygon**, has balance credited on **Arbitrum (hub)** within ~30s–2min via **LayerZero V2-confirmed cross-chain credits**, lends/borrows against that balance (existing flows), then withdraws back to any supported chain with sufficient liquidity. All tracked through `BalanceLedger.sol` with 3 sub-states (`available`, `inOrders`, `inYieldRouter`) plus a per-(user, asset) **on-chain** `usedAsCollateral` flag.

**Phase 1 cross-chain ≠ launch.** The hub-only launch carves out the cross-chain dependencies (LayerZero, spokes, sweeper bot, multi-chain UI) and ships the hub-resident lending protocol first. Cross-chain is the follow-on once hub-only is live and stable.

### What ships in cross-chain (when reactivated)

- **5-chain deployment**: hub on Arbitrum + 4 spokes (Base, Ethereum, BNB, Polygon-deferred-until-stable-testnet)
- **LZ-confirmed credit flow** (no solver in Phase 1; solver fast-fill deferred — see §9)
- **SPOKE_NATIVE custody** for non-bridgeable tokens (XSGD, IDRX, XAUT, Ondo RWAs) with `ChainLiquidity[token][chainId]` per-chain accounting
- **Sweeper Bot (M7)** for background spoke→hub custody reconciliation of BRIDGED tokens
- **Indexer-v3 spoke processors** for `SpokeDepositGateway.DepositInitiated`, `HubIntentSettler.DepositConfirmed`, etc.
- **Frontend M10 Phase 2** cross-chain UI (source/target chain selectors, per-chain portfolio breakdown, refund UX)

---

## 2. Architecture Decisions (C1–C11)

These were resolved during Phase 1 design. Each becomes a constraint on the cross-chain implementation.

### C1. One-click gasless + signatureless UX

Placing, cancelling, and replacing orders must be single-button — no signing, no gas, no waiting on a wallet popup (Hyperliquid / dYdX v4 / Lighter feel).

The current Centuari stack already achieves this: orders route through backend (Privy JWT auth) to matching engine over NATS, with zero per-order on-chain signatures. Cross-chain doesn't change order placement — only where matching engine gets its balance view (was: backend state; now: shared Postgres schema written by indexer-v3 + eager-path services).

**Phase 1 order flow:**
1. User opens app → Privy session established → backend issues session JWT
2. User clicks "Lend 100 USDC at 8% / 30d" → frontend POSTs to backend with JWT (zero wallet prompts)
3. Backend validates JWT + balance/HF, INSERTs order `status=OPEN`, forwards to engine via NATS
4. Engine matches in-memory without re-validating (backend already enforced the balance/HF check) — the matching-engine BalanceLedgerClient model originally specced in C3 was **superseded** by the backend-validated + db-writer-locked + settlement-released model
5. Cancel / replace are NATS messages — zero signatures, zero tx, zero gas. (One known race window: cancel-during-match — see [`order-lock-lifecycle-followups.md`](./archive/order-lock-lifecycle-followups.md))
6. db-writer (matching-engine codebase) writes the `matches` row + increments `portfolio.locked_amount`. Settlement-engine batches matches, submits batch on-chain with PROTOCOL settlement key. On settlement success: flips `matches.settlement_status PENDING → SETTLED` + decrements `portfolio.locked_amount`

**Consequence for BalanceLedger:** `inOrders` is NOT used in Phase 1 (forward-compat for Phase 6 `CentuariRouter`). Phase 1 BalanceLedger writes `available` (via credit/debit) and `usedAsCollateral` flag during settlement and explicit flag/unflag.

### C2. BalanceLedger writer registry + 48h timelock

Phase 1's Centuari.sol is the authorized writer to BalanceLedger until Phase 3 adds CentuariEndpoint. BalanceLedger writer-registration must support **add/remove over time** without contract upgrade — initial set small to keep blast radius low.

**Resolution:** BalanceLedger starts with `Centuari.sol` + governance role that can add/remove writers under 48h timelock. `HubDepositor`, `CollateralManager`, `Settlement` added at deploy. YieldRouter, WithdrawalRegistry, CentuariEndpoint, LiquidationEngine added later via governance.

### C3. Matching engine balance read — superseded model

**Original resolution (2026-04, pre-supersession):** engine reads `BalanceLedger.available(user, asset)` from indexer-v3 + Redis reservation counter at order placement.

**Current resolution (Phase 1A + 1B, shipped 2026-05-10):** engine does **not** read on-chain balance and does **not** maintain Redis reservation counter. Backend is the single validation surface:

```
Place-Order:
  Backend validates JWT + order shape
            LEND:   wallet − portfolio.locked_amount − sum_open_orders ≥ amount + fees
            BORROW: HF(current_debt + open_borrow_orders + pending_borrow_matches + new_borrow)
                    ≥ 1 + risk.borrow_buffer_bps/10000 (default 100)
  Backend INSERTs orders row, status=OPEN
  Backend publishes to NATS — engine matches without re-validation

Match:
  Engine matches → Redis Stream "settlement:matches"
  DB-writer consumes → INSERTs matches row + UPDATE portfolio.locked_amount += matched + fees

Settlement:
  Settlement-engine consumes match → encodes batch → submits on-chain
  After receipt: UPDATE matches.settlement_status PENDING → SETTLED
                 UPDATE portfolio.locked_amount −= matched + fees (lock-release.ts)
```

The engine no longer needs `BalanceLedgerClient`. Backend owns balance/HF; db-writer owns lock increment; settlement-engine owns lock decrement.

### C4. Solver capital — deferred

Full Architecture §2.7: solver must hold "20% of peak 24h deposit volume per spoke" as hub-side balance. For 5 spokes and non-trivial volume this is impractical capital for a startup at launch.

**Resolution:** solver fast-fill **deferred entirely from Phase 1**. Cross-chain deposits use **LZ-confirmed credit** flow (`SpokeDepositGateway` escrow → LZ message → `HubIntentSettler.confirmDeposit` → `BalanceLedger.credit`, ~30s–2min). Sweeper Bot bridges spoke→hub in background. Solver-path contracts (`HubIntentSettler.fillFor`, `SettlementLedger`) remain in codebase as **dormant infrastructure** — activate when volume justifies capital. See §9.

### C5. Cross-chain deposit IS the intent — no EIP-712 signing

User signs only the on-chain tx that locks their tokens on the spoke. No off-chain intent construction.

**Phase 1 flow:**
1. User clicks "Deposit 100 USDC from Base"
2. Wallet opens → user confirms ONE tx: `SpokeDepositGateway.deposit(asset, amount, hubRecipient)` (or `permitAndDeposit` for EIP-2612). User pays gas on Base.
3. `SpokeDepositGateway` escrows tokens + emits `DepositInitiated(depositId, user, asset, amount, hubRecipient)`. `depositId = keccak256(chainId, tx.origin, nonce)`. **This event is the intent.**
4. `SpokeDepositGateway` dispatches LZ message to hub carrying `(depositId, user, asset, amount, sourceChainId)`
5. Hub's `HubIntentSettler.confirmDeposit` (LZ receiver) verifies origin, credits `BalanceLedger.available[user] += amount`, marks `depositId` `CREDITED`
6. User's balance appears on Arbitrum in **~30s–2min**
7. Sweeper Bot bridges escrowed tokens spoke → hub via CCTP/Stargate in background (5–20 min) for custody reconciliation

**Refund path (timeout-based):** user calls `SpokeDepositGateway.refund(depositId)` after `REFUND_WINDOW` (30 min) if no credit issued. Double-credit prevented by `_depositStatuses[depositId] == CREDITED` check.

### C6. indexer-v3 custom build (Ponder rejected)

Docker-compose references `indexer-v3/` but directory didn't exist before Phase 1. Ponder forces framework-shaped schema/handler model that did not fit multi-chain state rollups (e.g., a single user's balance reflects events from hub + all four spokes in one `UserBalance` row).

**Resolution:** Module 8 builds custom Node/TypeScript indexer using Viem `watchEvent` + `getLogs` with Postgres backend, fully user-controlled schema. Same stack conventions as backend-v2 (TypeScript, pnpm, Viem, raw `pg`, Biome). Exposes only `/health` + `/metrics` — no consumer-facing data API. All reader services query shared Postgres schema directly via their own DB clients.

### C7. LayerZero DVN configuration (security-critical)

§8.11 of architecture explicitly warns the default DVN config is a placeholder. Cross-chain launch needs DVN stacks set per pathway BEFORE going live.

**Resolution:**
- **Testnet:** 1-of-1 DVN (LayerZero Labs only) across all 4 spoke ↔ hub pathways
- **Mainnet:** 2-of-2 DVN (LayerZero Labs + Google Cloud) across all pathways. Both DVNs confirmed available on all 5 target chains.
- **3-of-3 liquidation pathway:** Phase 2 follow-up (no liquidation engine in Phase 1)
- `ConfigureDVN.s.sol` calls `OAppOptionsType3.setEnforcedOptions` + `EndpointV2.setConfig` per pathway. Config keyed by `{hubChainId, spokeChainId}` in `config/layerzero-dvn.json`.

### C8. Testnet migration — clean wipe

Existing Arbitrum Sepolia Treasury balances are discarded on cross-chain redeploy. Testers re-deposit via faucet. No migration script. Mainnet migration (later) needs a separate plan.

### C9. Arbitrum is the hub — no spoke contracts on Arbitrum

Spokes deploy to **Base, Ethereum, BNB, Polygon** only. Arbitrum gets `HubDepositor.sol` (M3, already shipped) as the direct-deposit entry point for hub-native deposits. Withdrawals targeting Arbitrum: `WithdrawalRegistry` → `HubDepositor.payoutDirect` (no LZ message).

Frontend target-chain selector includes "Arbitrum (direct)" as distinct from the four spokes.

### C10. Eager DB sync + indexer-v3 safety net (applyOnChainEffect)

**Two-writer pattern for every on-chain mutation.** The service that submitted the tx eagerly writes the resulting DB mutation as soon as the receipt lands and is verified. Indexer tails the same event in parallel as a **safety net**.

**The pattern:**
1. Service submits tx with Viem, awaits receipt
2. Service verifies receipt: `status == success`, expected event logs present, event args match
3. If verified, service applies mutation inside a transaction that also stamps `applied_by_tx_hash`, `applied_by_log_index`, `applied_by_block_hash`, `applied_by_block_number` on the row
4. If verification fails, service does NOT apply anything — indexer either backfills if tx silently succeeded, or never applies if tx genuinely reverted
5. Indexer processor checks `applied_by_tx_hash` before writing: same tx hash = no-op; unset or different = apply

**Helper:** `indexer-v3/src/shared/apply-on-chain-effect.ts` (published as `@centuari-labs/on-chain-effects` ^0.2.0). Takes `(txHash, expectedEventSelector, expectedArgsPredicate, mutationFn, [receipt], [logIndex])`. Version 0.2.0 added optional `receipt` (skip refetch) + `logIndex` (select specific log when one tx emits multiple matching events).

**Reorg handling unchanged:** indexer's reorg detector compares block hashes; rows whose `block_hash` was replaced are removed; replay from fork point.

#### C10.1. Consumer call-site catalog

| Flow | Tx submitter | Helper call site | Confirm endpoint? |
|---|---|---|---|
| Deposit (hub-native) | Frontend (wagmi) | backend-v2 `POST /deposit/confirm` | **Yes** |
| Deposit (cross-chain, spoke-initiated) | Frontend (wagmi, spoke) | backend-v2 `POST /deposit/confirm` — stamps `cross_chain_deposit (state=INITIATED)` | **Yes** |
| Lend | backend-v2 (protocol key) | inline after `viem.writeContract` in `/lend` handler | No |
| Repay | backend-v2 (protocol key) | inline after `Centuari.repay` | No |
| Withdraw (principal) | backend-v2 | inline after `WithdrawalRegistry.requestWithdrawal` | No |
| Withdraw-lend | backend-v2 | inline in `/withdraw-lend` handler | No |
| Collateral flag/unflag | backend-v2 | inline after `CollateralManager.{flagFor,unflagFor}` | No |
| Settlement batch | settlement-engine | inline after `Settlement.settle(batch)` | No |
| Sweeper bridge (M7) | sweeper-bot | inline after bridge tx | No |

**Rule:** each service eager-writes only the rows *it transacted to update*. Side-effect events emitted by the same tx (e.g. `BalanceLedger.Debited/Credited` from `Settlement.settle`, `CollateralFlagSet` from `Centuari.settleMatch` when borrower requested flags via `MatchData.collateralAssets`) are left to the indexer tail.

**Exception:** spoke-initiated cross-chain deposit has no eager writer for the hub-side credit. The LZ-delivered `HubIntentSettler.confirmDeposit` on Arbitrum is picked up only by the indexer tail.

#### C10.2. Why deposit is the only confirmation-endpoint flow

Deposit moves tokens *from the user's wallet* into protocol custody. The tx must originate from the wallet — backend cannot submit on the user's behalf. Other flows operate on balances already under protocol authority, so backend submits inline and helper-stamps in the same handler.

#### C10.3. Helper distribution (pnpm workspace)

`applyOnChainEffect` lives at repo root `on-chain-effects/` (published as `@centuari-labs/on-chain-effects` on GitHub Packages). Consumed by:
- `backend-v2` — `apply-repay.ts`, `apply-withdraw-lend.ts`, `apply-internals.ts`, collateral endpoints
- `settlement-engine` — `apply-settlement.ts`, `clearPendingCollateralFlagsFromReceipt`
- `indexer-v3` — every processor
- (future) `sweeper-bot` — bridge tx eager writes

**Runtime coupling is zero.** Services communicate only via NATS, Redis Streams, REST. Workspace is a build-time artifact for sharing one TypeScript file's idempotency logic.

#### C10.4. Two-writer invariant

Every mutable row has **two possible authors**: the eager-path service and the indexer tail. The four `applied_by_*` stamps make them idempotent: whoever writes first wins, whoever writes second sees the stamp and short-circuits. The indexer tail is **passive safety net**, not backfill — runs continuously, no "find missing rows" reconciliation.

### C11. Spoke-native custody + per-chain liquidity

Not all tokens can be bridged. IDRX (Base/BNB only), XAUT (ETH only), Ondo RWAs (ETH/BNB only) lack CCTP/Stargate pools or don't exist on Arbitrum at all. These use **SPOKE_NATIVE** custody: token stays on its origin spoke; hub tracks only accounting (BalanceLedger) + `ChainLiquidity[token][chainId]` per-chain liquidity map.

**Lend/borrow for SPOKE_NATIVE tokens** is fully supported via hub accounting — tokens don't move between chains, only accounting flows through hub.

**Limitation:** if all XSGD liquidity is on Base and a borrower wants Polygon, withdrawal is blocked until someone deposits XSGD on Polygon. Acceptable for low-volume exotics. High-volume tokens use BRIDGED.

**No Sweeper rebalancing for SPOKE_NATIVE.** Liquidity distribution reflects organic deposits.

**Same LZ-confirmed flow.** Both BRIDGED and SPOKE_NATIVE deposits wait for LZ confirmation (~30s–2min); the difference is whether Sweeper later bridges (BRIDGED) or tokens stay on spoke (SPOKE_NATIVE).

---

## 3. Contracts — Cross-Chain Portion

### 3.1 HubIntentSettler (M4 — built, partly active in Phase 1)

**Path:** `src/core/cross-chain/HubIntentSettler.sol` (upgradeable, ERC1967 proxy)

**Phase 1 active function:**
- `confirmDeposit(depositId, user, asset, amount, sourceChainId)` — LZ V2 `lzReceive` entry point. Callable only by LZ endpoint from trusted `SpokeDepositGateway`. Verifies origin, rejects replay (`_depositStatuses[depositId]` tracking), credits `BalanceLedger.credit(user, asset, amount)`, marks `CREDITED`, emits `DepositConfirmed`. For SPOKE_NATIVE: increments `ChainLiquidity[asset][sourceChainId]`.

**Dormant (deferred with solver):**
- `fillFor(depositId, user, asset, amount, sourceChainId)` — solver fronts tokens. `onlyOperator` gated.
- `markNoFill(depositId)` — solver opts out. Unblocks spoke refund.
- `releaseToSolver(solver, asset, amount)` — called by SettlementLedger to release reimbursement.

**LZ V2 conformance** (critical — was bug source in M8 burn-in):
- `allowInitializePath(Origin) view returns (bool)` — required by `EndpointV2._initializable()` to permit first-time delivery paths. Returns `_trustedRemotes[origin.srcEid] != bytes32(0) && origin.sender == expected`.
- `lzReceive(Origin origin, bytes32 guid, bytes message, address executor, bytes extraData) payable` — **arg order must match LZ V2 `ILayerZeroReceiver` standard exactly.** Selector is `0x13137d65`. M8 burn-in surfaced a wrong-order signature in pre-patch code (see §5 Bug 4).
- Trusted remotes set via owner-only `setTrustedRemote(eid, peer)`.

### 3.2 SettlementLedger (M4 — built, dormant in Phase 1)

**Path:** `src/core/cross-chain/SettlementLedger.sol` (upgradeable)

Tracks solver reimbursement obligations. All functions remain for future solver activation; not called by any Phase 1 flow.

- `register(orderId, solver, asset, amount)` — called by `HubIntentSettler.fillFor` on solver fill
- `match(depositId, bridgedAmount)` — called by Sweeper Bot after bridge confirmation. Releases reimbursement.
- State: `REGISTERED → BRIDGED → REIMBURSED`

### 3.3 WithdrawalRegistry cross-chain path (M4 — built, hub-native active)

**Path:** `src/core/cross-chain/WithdrawalRegistry.sol` (upgradeable)

**State machine:** `PENDING → PROCESSING → COMPLETED` (and `FAILED` terminal).

**First action of `requestWithdrawal(user, asset, amount, targetChainId)`:**
```solidity
require(riskModule.canWithdraw(user, asset, amount), WithdrawalBlockedByHF());
```
Closes the M1-rollback loophole — uniform HF enforcement applies to every caller (app users via backend OR direct on-chain integrators). Phase 1 stub `RiskModule.canWithdraw` returns `!balanceLedger.usedAsCollateral(user, asset)`. Phase 2 real computes post-withdrawal HF.

**For SPOKE_NATIVE tokens:** additionally checks `ChainLiquidity[token][targetChain] >= amount` and reverts `InsufficientChainLiquidity(targetChain, available, requested)`. Decrements `ChainLiquidity` atomically with BalanceLedger debit.

**Chain liquidity storage**: lives in `WithdrawalRegistryStorage._chainLiquidity` (M5 deviation — was originally planned as a separate `ChainLiquidityTracker.sol`).

**Cross-chain payout path** (currently dormant — needs Hub→Spoke burn-in, §8 F6):
- `authorize(requestId)` → PROCESSING → LZ message to target chain's `SpokePayout`
- `markCompleted(requestId)` on LZ ack → COMPLETED
- `markFailed(requestId)` on timeout → refunds user's `BalanceLedger.available`
- SLA: 4h. After 4h in PROCESSING, off-chain monitor escalates.

**SLA Note:** Hub→Spoke withdrawal path is built but NOT burn-in verified (only Spoke→Hub deposit verified in M8 — see §8 F6).

### 3.4 Spoke contracts (M5 — deployed to 4 spokes)

#### SpokeDepositGateway

**Path:** `src/core/cross-chain/spoke/SpokeDepositGateway.sol`

Built from scratch in M5 (absent from feat branch). Handles escrow + LZ message dispatch + refund.

- `deposit(asset, amount, hubRecipient)` — `safeTransferFrom`, escrows tokens (BRIDGED) or routes to `SpokeVaultStable` (SPOKE_NATIVE), emits `DepositInitiated`, dispatches LZ message
- `permitAndDeposit(...)` — EIP-2612 single-tx variant
- `refund(depositId)` — user-callable, BRIDGED only, gated on `REFUND_WINDOW` (30 min) timeout + `_depositStatuses[depositId] != CREDITED` check
- **LZ V2 options** (critical, was bug source in M8 burn-in): construction must include non-empty Type-3 options with executor `lzReceive` gas hint:
  ```solidity
  bytes private constant DEFAULT_LZ_OPTIONS =
    hex"00030100110100000000000000000000000000030d40";
  ```
  (Type-3 + ExecutorLzReceiveOption with 200,000 gas) — empty options revert with `LZ_ULN_InvalidWorkerOptions(uint256)`. See §5 Bug 1.

#### SpokeVaultStable (dual custody)

**Path:** `src/core/cross-chain/spoke/SpokeVaultStable.sol`

Holds both temporary escrow (BRIDGED, awaiting Sweeper) and permanent custody (SPOKE_NATIVE).

- `sweepToHub(asset, amount, hubAddress)` — Sweeper-only, BRIDGED tokens only. Routes by token×chain matrix: CCTP burn/mint for USDC (Base/ETH/Polygon), Stargate V2 pool transfer otherwise. Reverts `CannotSweepSpokeNative()` for SPOKE_NATIVE.
- `custodyBalance(asset) → uint256` — SPOKE_NATIVE permanent custody view
- `setGateway(addr)` / `setPayout(addr)` — owner-only authority registration. **Critical: ConfigureSpokeForM5.s.sol must call both.** See §5 Bug 2 (`Unauthorized()` on first deposit because never wired).
- `HIGH_WATER_MARK = 3× rolling 24h`, `LOW_WATER_MARK = 1× rolling 24h` — BRIDGED only

#### SpokePayout (dual mode)

**Path:** `src/core/cross-chain/spoke/SpokePayout.sol`

- `release(user, asset, amount)` — callable only after `WithdrawalRegistry` LZ authorization. For BRIDGED: releases from spoke's BRIDGED buffer (replenished by Sweeper). For SPOKE_NATIVE: releases from `SpokeVaultStable` custody.
- BRIDGED queue: FIFO `_pendingPayouts[user][asset][]` if buffer insufficient (queues until Sweeper replenishes). No depth cap.
- LZ V2 conformance: same `allowInitializePath` + `lzReceive` standard signature as `HubIntentSettler`. See §5 Bugs 3, 4.

### 3.5 Storage layouts + access control

Every cross-chain contract uses the project's `*Storage.sol` + `__gap` pattern. ProxyAdmin controls upgrades, separate from contract owner.

| Contract | Owner | Operator role |
|---|---|---|
| HubIntentSettler | governance | LZ endpoint (peer-gated) |
| SettlementLedger | governance | HubIntentSettler |
| WithdrawalRegistry | governance | Centuari + LZ endpoint |
| SpokeDepositGateway | governance | LZ endpoint |
| SpokeVaultStable | governance | Gateway + Payout (registered via setGateway/setPayout) |
| SpokePayout | governance | LZ endpoint |

### 3.6 M5 implementation deviations (audit record)

1. **Refund semantics:** timeout-based (30 min) + hub-side `_depositStatuses[depositId] == CREDITED` idempotency. Simpler than original "hub LZ confirmation" sketch.
2. **Chain liquidity storage:** inside `WithdrawalRegistryStorage._chainLiquidity` mapping, not standalone `ChainLiquidityTracker.sol`. Reversible if M9 needs cross-contract reads.
3. **Trusted remote config:** owner-only `setTrustedRemote(eid, peer)` on `HubIntentSettler` rather than separate registry.
4. **No OAppSender/OAppReceiver inheritance:** LZ V2 package ships non-upgradeable variants only (immutable endpoint). All spoke + hub contracts store `_endpoint` + `_peers` in `*Storage` and call endpoint directly. Migration to `@layerzerolabs/oapp-evm-upgradeable` is a possible follow-up.
5. **SpokePayout bridged queue:** per-user per-asset array with FIFO flush. No depth cap.

**M5 final test count:** 438 (339 hub baseline + 99 M5 additions across 6 new test files).

---

## 4. Off-Chain Services — Cross-Chain Portion

### 4.1 Indexer-v3 cross-chain processors

**Path:** `indexer-v3/src/processors/`

One `ChainWatcher` per chain (5 total in full cross-chain mode: hub + 4 spokes). Each uses Viem `createPublicClient` with WS transport (HTTP fallback). `BlockCursor` table per chain tracks last fully-processed block.

**Reorg handling:** per-chain finality depth — `N = 12` for hub (Arbitrum), `N = 64` for Ethereum, `N = 32` for others. On every new head, compare recent N-block hashes against stored; if divergence, delete rows where `block > fork-point` and replay.

**Cross-chain processors** (built, all 5 verified in M8 burn-in for Arb+Base, unverified for Eth/BNB/Polygon):
- `spoke-deposit-gateway.processor.ts` — handles `DepositInitiated` → seeds `cross_chain_deposit (state=INITIATED)`
- `hub-intent-settler.processor.ts` — handles `DepositConfirmed` (LZ-confirmed credit) → updates `cross_chain_deposit (state=CREDITED)`. Solver-related events (`SolverFillRegistered`) decode gracefully but never fire in Phase 1.
- `spoke-vault.processor.ts` — handles spoke custody events (sweep, payout)
- `withdrawal-registry.processor.ts` — handles state transitions
- `settlement-ledger.processor.ts` — **dormant in Phase 1** (no solver reimbursement). Stub kept for forward compat.

**Hub processors** (also used in hub-only):
- `balance-ledger.processor.ts` — `Credited`/`Debited` → `user_balance.available`; `CollateralFlagSet(writer, user, asset, used, flaggedAt)` (5 params) → `user_balance.used_as_collateral` + `flagged_at`. Stamps four `applied_by_*` columns.
- `centuari.processor.ts` — Order/Match/Repay/Bond mint events. Phase-1 `Centuari.repay` does NOT emit `CollateralFlagSet` (flags persist through repay per P1b-explicit), so this processor doesn't touch flag rows.
- `hub-depositor.processor.ts` — Deposit/Payout events on Arbitrum

**Cross-chain schema additions:**

```sql
CREATE TABLE cross_chain_deposit (
  deposit_id BYTEA PRIMARY KEY,
  user_address BYTEA NOT NULL,
  source_chain BIGINT NOT NULL,
  asset BYTEA NOT NULL,
  amount NUMERIC(78,0) NOT NULL,
  custody_type TEXT NOT NULL,    -- BRIDGED | SPOKE_NATIVE
  state TEXT NOT NULL,           -- INITIATED | CREDITED | BRIDGED | REFUNDED
  initiated_at TIMESTAMPTZ NOT NULL,
  credited_at TIMESTAMPTZ,       -- when hub confirmed via LZ
  bridged_at TIMESTAMPTZ,        -- when Sweeper bridged (BRIDGED only)
  applied_by_tx_hash BYTEA,
  applied_by_log_index INT,
  applied_by_block_hash BYTEA,
  applied_by_block_number BIGINT
);
-- Note: no `solver` column. When solver activates, table gains `solver BYTEA`
-- + `filled_at TIMESTAMPTZ` and state machine adds FILLED between INITIATED + CREDITED.
```

### 4.2 M7 Sweeper Bot (NOT STARTED, design intact)

**Path:** `sweeper-bot/` (new top-level service)

**Phase 1 scope (simplified):** pure bridge bot. No solver reimbursement.

**Files to create:**
- `sweeper-bot/package.json`
- `src/index.ts`
- `src/inbound-flow.ts` — monitors `DepositInitiated` events on spoke gateways for BRIDGED tokens. After hub LZ-confirms (BalanceLedger already credited), Sweeper calls `SpokeVaultStable.sweepToHub(asset, amount, hubAddress)` to bridge escrowed tokens via CCTP/Stargate. Background custody reconciliation — does NOT affect user-visible balance. After bridge tx lands, imports `applyOnChainEffect`, updates `cross_chain_deposit.state = BRIDGED`, stamps idempotency columns.
- `src/outbound-flow.ts` — hub → spoke replenishment for BRIDGED withdrawal buffers
- `src/bridge-client.ts` — wraps CCTP + Stargate. Routes by `token-chain-matrix.json` (CCTP for USDC on Base/ETH/Polygon; Stargate for USDC-on-BNB + USDT/WETH/WBTC pools)
- `src/water-marks.ts` — `HIGH_WATER_MARK = 3× rolling 24h`, `LOW_WATER_MARK = 1× rolling 24h`. BRIDGED tokens only.
- `Dockerfile`
- Update `docker-compose.yml` to add sweeper-bot service

**Out of scope for Phase 1 Sweeper:** `ledger-matcher.ts` / `SettlementLedger.match()` (no solver reimbursement); solver capital restoration.

**Monitoring:** Prom metrics — `sweeper_pending_bridges`, `sweeper_bridge_latency_ms`, `sweeper_last_event_age_s`. Alert if `sweeper_last_event_age_s > 1800` (30 min stale).

**Backup strategy:** primary is Centuari-run. Gelato-based backup is Phase 2+. For Phase 1 testnet, single Sweeper is SPOF (documented).

### 4.3 Backend-v2 cross-chain pieces

**`POST /deposit/confirm` cross-chain branch** ([`backend-v2/src/deposit/`](../../backend-v2/src/deposit/)):
- Frontend POSTs `{ txHash, sourceChainId }` from a spoke deposit
- Backend fetches receipt via Viem
- Calls `applyOnChainEffect` to verify `SpokeDepositGateway.DepositInitiated` event
- Eagerly seeds `cross_chain_deposit` row with `state=INITIATED`
- Returns updated state. Indexer tail confirms when LZ message arrives on hub (`HubIntentSettler.DepositConfirmed` → `state=CREDITED`); Sweeper later transitions `state=BRIDGED`.

**Withdrawal validation for SPOKE_NATIVE** (`backend-v2/src/withdraw/`):
- Checks `ChainLiquidity[token][targetChain] >= amount` via direct SQL on `user_balance` + ChainLiquidity tables before submitting tx
- Rejects HTTP 400 `InsufficientChainLiquidity { chain, available, requested }`

**`backend-v2/src/config/token-chain-matrix.ts`** — imports from `smart-contract-revamp/config/token-chain-matrix.json`. Used by deposit validation (reject unsupported token×chain pairs), withdrawal validation (reject impossible routes), portfolio display.

### 4.4 Settlement engine (no cross-chain-specific work)

Settlement-engine doesn't change for cross-chain — match flows are hub-local. Only the eager-write pattern (§4.5) applies; that's shipped.

### 4.5 Eager-write pattern (Phase A, shipped)

Status from `phase-a-settlement-engine-eager-writes.md`:

| Step | Status |
|---|---|
| A1 — Capture full receipt metadata in settlement-engine | ✅ DONE |
| A2 — Add shared helper dep (`@centuari-labs/on-chain-effects ^0.2.0`) | ✅ DONE |
| A3 — Schema audit + migration (none needed) | ✅ DONE |
| A4 — Rewrite settlement-engine persistence onto `applyOnChainEffect` | ✅ DONE |
| A5 — Migrate backend-v2 onto shared on-chain-state schema | ✅ DONE |
| A6 — Delete legacy backend-v2 UUID tables + entities + DROP TABLE migration | ⚪ NOT STARTED |

**Key invariant for cross-chain:** the helper's 0.2.0 added `receipt` (skip refetch when caller has receipt) + `logIndex` (select specific log when one tx emits multiple matching events). **Required** because a `settleMatches(batch)` tx can emit multiple `LendPositionCreated`/`BorrowPositionCreated` logs sharing the same `(marketId, lender|borrower)` key; without `logIndex` the helper would apply only the first and silently drop the rest.

**Settlement-engine call shape** ([`apply-settlement.ts`](../../settlement-engine/src/settlement/database/apply-settlement.ts)):

```ts
for (const event of result.lendPositionEvents) {
  await applyOnChainEffect<LendPositionCreatedArgs>({
    client, pool,
    receipt,                      // pre-fetched — no refetch
    txHash: receipt.transactionHash,
    expectedEventTopic: LEND_POSITION_CREATED_TOPIC0,
    logIndex: event.logIndex,
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
```

`rate` is **latest-wins** (`EXCLUDED.rate`), matching indexer tail. Both writers must stay byte-for-byte identical for C10 idempotency.

---

## 5. M8 Burn-In: What Shipped + What's Left

**Status:** ✅ DONE 2026-05-06 for Spoke (Base Sepolia) ↔ Hub (Arb Sepolia) BRIDGED path. End-to-end LZ V2 round-trip verified live. **Eth Sepolia + BNB Testnet spokes NOT YET PATCHED** with the 5 bug fixes; Polygon Amoy deferred.

### 5.1 End-to-end verification evidence (Base Sepolia → Arb Sepolia)

Deposit `0x2afaac2d…626483` made the full round trip:

| Step | Chain | Block | Tx | Indexer row state |
|---|---|---|---|---|
| `SpokeDepositGateway.DepositInitiated` | Base Sepolia (40245) | 41,074,237 | `0x28859d20af597b35547b997639718b9eb54918599b4b18f9a5b437ce5f74052c` | `cross_chain_deposit` INSERTED, `state=INITIATED` |
| LZ V2 relay | (off-chain) | — | — | — |
| `HubIntentSettler.DepositConfirmed` | Arb Sepolia (40231) | 265,677,851 | `0x8f99a27a0f311f65457008465da4892aa3c98aeec1999622327c8060357aac56` | Same row UPDATED, `state=CREDITED`, `credited_tx` stamped |
| `BalanceLedger.Credited` | Arb Sepolia | 265,677,851 | (same tx) | `user_balance` INSERTED, `available=1,000,000` for user `0x477dcb9AE…EfE1` / asset `0x51138a4bf…e70b3` |

**End-to-end latency:** ~22 min (LZ V2 testnet, low-priority free pathway).

**Processors verified against live events:**
1. ✅ `spoke-deposit-gateway.processor.ts` (DepositInitiated → cross_chain_deposit INITIATED)
2. ✅ `hub-intent-settler.processor.ts` (DepositConfirmed → cross_chain_deposit CREDITED)
3. ✅ `balance-ledger.processor.ts` (Credited → user_balance.available)

**Centuari positions processor** (`MarketCreated` / `BorrowPositionCreated` / `LendPositionCreated` / `Repaid` / `LendPositionWithdrawn`): covered by hub-only burn-in 2026-04-21.

**On-chain upgrades performed during burn-in:**

| Contract | Chain | New implementation |
|---|---|---|
| SpokeDepositGateway | Base Sepolia (84532) | `0x3788195123B6C9E14DCB4E8d3de263C3867AEC70` (LZ options fix) |
| HubIntentSettler | Arb Sepolia (421614) | `0x3a1eEd829949049Fd8227D547458b4aEd99D9FCd` (allowInitializePath + lzReceive sig fix) |
| SpokePayout | Base Sepolia | `0x89f32b5f659a71c16DA01Be808059e787e472217` (allowInitializePath + lzReceive sig fix) |

ProxyAdmin owners still the burn-in deployer. Storage layouts unchanged.

**Same patches needed on Eth Sepolia + BNB Testnet** (see §8 F2). Polygon Amoy deferred (insufficient testnet POL, unstable RPC).

### 5.2 Five contract bugs surfaced + patched

All real production issues, not testnet-only. Each upstream of the previous: you can only see bug N once bug N-1 is fixed.

#### Bug 1 — SpokeDepositGateway empty LayerZero options

**Symptom:** `LZ_ULN_InvalidWorkerOptions(uint256)` revert at first byte of options blob during `endpoint.quote()`. Every deposit reverted before tokens could even be approved.

**Root cause:** Both `_lzSend` and `quoteDeposit` constructed `MessagingParams` with `options: bytes("")`. LZ V2 UltraLightNode requires non-empty Type-3 options including executor `lzReceive` gas hint.

**Fix:**
```solidity
bytes private constant DEFAULT_LZ_OPTIONS =
  hex"00030100110100000000000000000000000000030d40";
// Type-3 + ExecutorLzReceiveOption with 200,000 gas
```

**Production impact:** ALL deposits on ALL spokes blocked until patched. Same bug applies to Eth/BNB/Polygon spoke contracts.

#### Bug 2 — SpokeVaultStable.setGateway / setPayout never called

**Symptom:** `Unauthorized()` revert from `SpokeVaultStable.depositBridged` because vault's `_gateway` was zero. Caller (`SpokeDepositGateway`) failed `onlyGateway` modifier.

**Root cause:** Post-deploy wiring scripts (`deploy-spoke.sh`, `ConfigureSpokeForM5.s.sol`) registered LZ peers but never registered gateway/payout authorities on the vault.

**Fix (interim, manual):** `cast send vault setGateway(gateway)` and `cast send vault setPayout(payout)` for Base Sepolia. Eth/BNB/Polygon need same wiring for production.

**Better fix (✅ DONE 2026-05-09):** `script/ConfigureSpokeForM5.s.sol` now calls `vault.setGateway(gatewayAddr)` and `vault.setPayout(payoutAddr)` between LZ peer wiring and asset classification. Future spoke deploys via `bin/run-all-cross-chain.sh` phase C are wired automatically.

#### Bug 3 — HubIntentSettler + SpokePayout missing allowInitializePath()

**Symptom:** LZ scanner reported `BLOCKED: Not Initializable` for every cross-chain message. DVN never even started verification.

**Root cause:** LZ V2's `EndpointV2._initializable()` calls `receiver.allowInitializePath(origin)` to decide whether a brand-new `(srcEid, sender, nonce)` tuple can establish a delivery path. Our custom OApps didn't inherit OAppCore so the method was missing.

**Fix:**
```solidity
function allowInitializePath(Origin calldata origin) external view returns (bool) {
    bytes32 expected = _trustedRemotes[origin.srcEid]; // or _peers on SpokePayout
    return expected != bytes32(0) && origin.sender == expected;
}
```

#### Bug 4 — lzReceive arg order doesn't match LZ V2 standard

**Symptom:** LZ scanner: `FAILED — Executor transaction simulation reverted` with empty revert data. Multiple retries failed identically.

**Root cause:** Custom `lzReceive` was declared:
```solidity
function lzReceive(Origin, address /*receiver*/, bytes32 /*guid*/, bytes message, bytes /*extraData*/)
```
LZ V2's `ILayerZeroReceiver` standard is:
```solidity
function lzReceive(Origin, bytes32 guid, bytes message, address executor, bytes extraData) payable
```
Function selectors differ (`0x...` vs `0x13137d65`). Endpoint's calldata couldn't ABI-decode against our function — `bytes32 guid` lined up where we expected `address`, dynamic `bytes` offset lined up where we expected `bytes32`, etc. Silent revert with empty data.

**Why unit tests didn't catch it:** `test/mocks/MockLZEndpoint.sol` was written to match the wrong signature. Both the wrong-signature contract and wrong-signature mock agreed → tests passed. **Mock-mirror-bug** anti-pattern.

**Fix:** Swapped arg order in both contracts + MockLZEndpoint + 10 test call sites (`HubIntentSettler.confirmDeposit.t.sol`, `SpokePayout.t.sol`). 235/235 tests pass post-fix.

#### Bug 5 — Orchestrator polish

**Symptom:** `bin/run-all-cross-chain.sh` had several iterations during burn-in: skip-spoke handling, idempotent retries, pipefail, env var name mapping for `SPOKE_ETHEREUM_*`.

**Fix:** clean up + add unit tests. **Status: outstanding** (PR5 in §8 F1).

### 5.3 New tooling delivered

| File | Purpose |
|---|---|
| `bin/run-all-cross-chain.sh` | Master orchestrator. 6 resumable phases A–F. `--phase=` to run subsets. Idempotency markers + dry-run + private-key redaction. |
| `bin/lz-testnet-config.sh` | Sourceable bash with verified LZ V2 endpoint addresses + EIDs for all 5 testnets. |
| `script/ConfigureSpokeForM5.s.sol` | Mirror of `ConfigureHubForM5.s.sol`. Sets spoke-side LZ peers + BRIDGED/SPOKE_NATIVE asset classifications on gateway and vault + (post-2026-05-09) registers vault authorities. |
| `script/BurnInSpokeDeposit.s.sol` | Burn-in trigger: approve + `quoteDeposit` + `deposit{value: fee}`. Reads SPOKE_GATEWAY / BURN_IN_ASSET / BURN_IN_AMOUNT from env. |

### 5.4 What's NOT verified by M8 burn-in

- **Spoke→Hub SPOKE_NATIVE deposit path** — only BRIDGED (USDC) tested. SPOKE_NATIVE (XSGD/IDRX/RWAs) requires asset classification + vault funding. Mechanically same code path; `classification == 2` in payload.
- **Hub→Spoke withdrawal path** — `WithdrawalRegistry` → LZ → `SpokePayout` NOT exercised. SpokePayout upgraded with same fixes; path SHOULD work but needs its own burn-in.
- **Centuari positions processor on fresh post-orchestrator deploy** — covered by 2026-04-21 hub-only burn-in.
- **Polygon Amoy spoke** — deferred. Insufficient testnet POL, unstable RPC.
- **Reorg handling on real testnet reorgs** — only synthetic block-hash divergence verified in unit tests.

### 5.5 Indexer-v3 state at M8 completion

- 4 ChainWatchers tailing live (HUB Arb Sepolia, SPOKE_BASE, SPOKE_ETHEREUM, SPOKE_BNB). POLYGON deferred.
- `cross_chain_deposit` contains 4 INITIATED rows + 1 CREDITED row (the burn-in deposit #4).
- 3 older INITIATED deposits stuck because their LZ messages were sent BEFORE patches; LZ executor doesn't retry simulations that already definitively failed pre-patch. Could be manually re-driven or just ignored — stale test data.
- All processors stamp four `applied_by_*` columns per C10.

---

## 6. M8 Burn-In Runbook

Preserved from `m8-burn-in-runbook.md` so anyone re-running burn-in for additional spokes has the operator instructions inline.

### 6.1 Phases at a glance

Phases A–F are wrapped in `bin/run-all-cross-chain.sh`. Each phase writes a marker file under `.run-all-cross-chain-state/` so reruns skip completed phases.

| Phase | What | Driver | Time | Output |
|---|---|---|---|---|
| **0** | Prereqs — fresh key, RPC URLs, fund wallet, env scaffold | manual | 30–60 min | `.env` + `.env.chains` populated, wallet funded |
| **A** | Hub stack to Arbitrum Sepolia | `run-all-cross-chain.sh --phase=A` (calls `run-all.sh`) | 30–45 min | `deploy-arb-sepolia-latest.json` |
| **B** | Spoke deploys × 4 (+ mock USDC per spoke) | `--phase=B` (calls `deploy-spoke.sh` + `DeployMockTokens`) | 30–45 min | 4× `deploy-spoke-<chainId>-latest.json` |
| **C** | Spoke-side LZ wiring + asset classification × 4 | `--phase=C` (calls `ConfigureSpokeForM5.s.sol`) | 10 min | Spoke peers + BRIDGED USDC registered + vault.setGateway/setPayout |
| **D** | Hub-side LZ wiring | `--phase=D` (calls `ConfigureHubForM5.s.sol`) | 10 min | Hub trusted remotes + payout peers registered |
| **E** | Unified `deploy-cross-chain-latest.json` summary | `--phase=E` | <1 min | Aggregated hub + 4 spoke addresses |
| **F** | Auto-populate `indexer-v3/.env` from unified summary | `--phase=F` | <1 min | Indexer ready to tail 5 chains |
| **G** | Live burn-in: trigger spoke deposit, watch indexer process LZ-confirmed credit, trigger settlement | ✅ DONE 2026-05-06 (Base only) | 30 min | M8 done |

Flags: `--dry-run` (print plan without sending tx), `--reset` (clear all phase markers), `--verify` (Etherscan verification), `--skip-indexer-env`.

### 6.2 Phase 0 prereq checklist

Work through every box. **Don't paste any private key, RPC URL, or API key into chat.**

#### 0.1 — Widen .gitignore

`smart-contract-revamp/.gitignore` line 12: change `.env` → `.env*` so overlay files are auto-ignored. Verify: `git check-ignore -v smart-contract-revamp/.env.chains`.

#### 0.2 — Generate fresh single-purpose testing key

`cast wallet new`. Copy address + key to password manager. **Never anywhere else.** This key becomes deployer of every contract + OWNER of every proxy + PROXY_ADMIN_OWNER. Rotate after burn-in.

#### 0.3 — Populate smart-contract-revamp/.env

```bash
PRIVATE_KEY=0x<from 0.2>
RPC_URL=<placeholder; overridden per phase>
ETHERSCAN_API_KEY=<your multichain key>
CENTUARI_OWNER=0x<deployer>
PROXY_ADMIN=0x<deployer>
BACKEND_OPERATOR=0x<deployer>
SETTLEMENT_OPERATOR=0x<deployer>
TREASURY_ADDRESS=0x<deployer>
```
Deployer-as-everyone is fine for burn-in. Mainnet uses separate multisigs.

#### 0.4 — Create smart-contract-revamp/.env.chains

`chmod 600`, owner-only read/write. Populate HTTP + WS RPC URLs for all 5 chains. Recommended: Alchemy free tier (300M CU/month) covers Arb/Base/Eth/Polygon; QuickNode or public RPC for BNB testnet.

```bash
ARB_SEPOLIA_RPC_URL_HTTP=https://arb-sepolia.g.alchemy.com/v2/<key>
ARB_SEPOLIA_RPC_URL_WS=wss://arb-sepolia.g.alchemy.com/v2/<key>
BASE_SEPOLIA_RPC_URL_HTTP=...
BASE_SEPOLIA_RPC_URL_WS=...
ETH_SEPOLIA_RPC_URL_HTTP=...
ETH_SEPOLIA_RPC_URL_WS=...
BNB_TESTNET_RPC_URL_HTTP=https://data-seed-prebsc-1-s1.binance.org:8545
BNB_TESTNET_RPC_URL_WS=wss://bsc-testnet.publicnode.com
POLYGON_AMOY_RPC_URL_HTTP=...
POLYGON_AMOY_RPC_URL_WS=...
```

#### 0.5 — Fund deployer wallet

| Chain | Recommended | Faucet |
|---|---|---|
| Arbitrum Sepolia | **0.5 ETH** | Alchemy faucet or pk910 PoW (then bridge) |
| Base Sepolia | 0.05 ETH | Alchemy or Coinbase faucet |
| Ethereum Sepolia | 0.05 ETH | Alchemy (GH-gated), QuickNode, or pk910 PoW |
| BNB Testnet | 0.05 BNB | bnbchain.org/en/testnet-faucet |
| Polygon Amoy | 0.05 POL | faucet.polygon.technology |

Verify each balance with `cast balance --rpc-url ... <deployer>`.

#### 0.6 — Connectivity sanity

```bash
for VAR in ARB_SEPOLIA_RPC_URL_HTTP BASE_SEPOLIA_RPC_URL_HTTP ETH_SEPOLIA_RPC_URL_HTTP BNB_TESTNET_RPC_URL_HTTP POLYGON_AMOY_RPC_URL_HTTP; do
  URL="${!VAR}"
  BLOCK=$(cast block-number --rpc-url "$URL" 2>/dev/null || echo "FAIL")
  echo "$VAR  →  block=$BLOCK"
done
```
All 5 should print a recent block number.

### 6.3 Phases A–G — Recommended invocation

Run one phase at a time and inspect output:

```bash
./bin/run-all-cross-chain.sh --phase=A   # hub deploy (~30–45 min, ~0.4 ETH)
./bin/run-all-cross-chain.sh --phase=B   # 4 spoke deploys + mock USDC each (~30 min, ~0.04 ETH per spoke)
./bin/run-all-cross-chain.sh --phase=C   # spoke-side wiring (~10 min)
./bin/run-all-cross-chain.sh --phase=D   # hub-side wiring (~5 min)
./bin/run-all-cross-chain.sh --phase=E   # unified summary
./bin/run-all-cross-chain.sh --phase=F   # populate indexer-v3/.env
```

**Phase G** (live burn-in trigger): start indexer, trigger spoke deposit via `BurnInSpokeDeposit.s.sol`, watch `cross_chain_deposit` row transition `INITIATED → CREDITED` (~30s–2min on testnets). Then trigger `Settlement.settleMatches()` on hub to validate Centuari positions processor.

### 6.4 Verification commands

```bash
# 1. Confirm CREDITED row exists in indexer DB
docker exec centuari-v2-postgres-1 psql -U centuari -d centuari -c "
  SELECT '0x'||encode(deposit_id,'hex') AS deposit_id, source_chain, amount,
         state, initiated_at, credited_at,
         '0x'||encode(applied_by_tx_hash,'hex') AS credited_tx
  FROM cross_chain_deposit WHERE state='CREDITED';
"

# 2. Confirm user_balance reflects the credit
docker exec centuari-v2-postgres-1 psql -U centuari -d centuari -c "
  SELECT '0x'||encode(user_address,'hex') AS user_address,
         '0x'||encode(asset,'hex') AS asset, available
  FROM user_balance;
"

# 3. Verify on Arbiscan
# https://sepolia.arbiscan.io/tx/0x8f99a27a0f311f65457008465da4892aa3c98aeec1999622327c8060357aac56

# 4. Verify on LayerZero scan
# https://testnet.layerzeroscan.com/tx/0x28859d20af597b35547b997639718b9eb54918599b4b18f9a5b437ce5f74052c
```

---

## 7. Frontend M10 Phase 2 (Cross-Chain UI) — NOT STARTED

Per `phase-1-cross-chain-balance-ledger.md` Module 10.

### Components to build

- **`centuari-deposit/`** — token-aware source-chain selector driven by `token-chain-matrix.json`. For each token, shows chains where `CustodyType != —`. Options: "Arbitrum (direct)" (HubDepositor, ~15s) + spoke chains (`SpokeDepositGateway`, ~30s–2min LZ confirmation). SPOKE_NATIVE deposits show "Token will remain on {chain} for custody."
- **`centuari-withdraw/`** — token-aware + liquidity-aware target-chain selector. For BRIDGED: all bridge-supported chains. For SPOKE_NATIVE: per-chain liquidity from `ChainLiquidity[token][chainId]`, greys out chains with 0 liquidity.
- **Portfolio per-chain balance breakdown** for SPOKE_NATIVE tokens.

### Hooks

- **`use-deposit.ts`** — single `useWriteContract` call. Arbitrum direct → `HubDepositor.deposit(asset, amount)`. Spokes → `SpokeDepositGateway.permitAndDeposit(...)` or approve+deposit. **No `signTypedData`, no intent construction.** Polls backend `cross_chain_deposit` state for cross-chain progress (`INITIATED → CREDITED → BRIDGED`).
- **`use-withdraw.ts`** — withdrawal state tracking via backend polling.
- **`use-chain-liquidity.ts`** — reads `ChainLiquidity[token][chainId]` for withdrawal selector.

### Lib

- **`lib/chain-config.ts`** — exports `getDepositChains(token): ChainConfig[]` and `getWithdrawChains(token): ChainConfig[]`. SPOKE_NATIVE `getWithdrawChains` needs live liquidity lookup.
- **`lib/portfolio-data.ts`** — extends to surface 3 sub-states per asset (only `available` non-zero in Phase 1) + per-chain breakdown for SPOKE_NATIVE.

### E2E specs

- **`e2e/cross-chain-deposit.spec.ts`** — deposit USDC on Base mock → balance appears on Arb portfolio after LZ confirmation (mocked LZ endpoint for local devnet).
- **`e2e/cross-chain-withdraw.spec.ts`** — withdraw to spoke chain, verify state transitions.
- **`e2e/refund-flow.spec.ts`** — initiate deposit, simulate LZ timeout, claim refund after 30 min.

### Refund UX

- Deposit row shows pending state with ETA (30s–2min normal; "Eligible for refund in X min" after 25 min).
- "Refund" button calls `SpokeDepositGateway.refund(depositId)` after timeout.

---

## 8. Open TODOs for After Hub-Only Launch

The actionable post-launch list. Source-doc references included for drill-in.

### F1. Ship M8 follow-up PRs through normal review

| PR | Source | Description |
|---|---|---|
| PR1 | `m8-burn-in-completion.md` §"Follow-up tasks" | SpokeDepositGateway LZ options fix on all 4 spoke chains. Add `bin/upgrade-spoke-gateway.sh` helper to apply the `DEFAULT_LZ_OPTIONS` constant + 2 call-site updates. |
| PR2 | `m8-burn-in-completion.md` §"Follow-up tasks" | HubIntentSettler + SpokePayout `allowInitializePath` + `lzReceive` sig rewrite. Match LZ V2 ILayerZeroReceiver standard `(Origin, bytes32 guid, bytes message, address executor, bytes extraData)`. |
| PR3 | `m8-burn-in-completion.md` §"Follow-up tasks" | MockLZEndpoint sig fix + 10 test rewrites. Bundle with PR2 (tests are coupled). |
| ~~PR4~~ | ✅ DONE 2026-05-09 | ConfigureSpokeForM5 wires vault.setGateway + vault.setPayout. |
| PR5 | `m8-burn-in-completion.md` §"Follow-up tasks" | Orchestrator polish on `bin/run-all-cross-chain.sh`: skip-spoke handling, idempotent retries, pipefail, `SPOKE_ETHEREUM_*` env var name mapping. Clean up + add unit tests. |

### F2. Upgrade Eth Sepolia + BNB Testnet spokes

Apply PR1–3 patches to spokes that weren't touched by the burn-in:

- Eth Sepolia: SpokeDepositGateway + SpokePayout
- BNB Testnet: SpokeDepositGateway + SpokePayout

`HubIntentSettler` on Arb Sepolia is already upgraded (universal for all spokes).

### F3. Build M7 Sweeper Bot

Per §4.2. New microservice. Substrate already verified (`applyOnChainEffect` from `@centuari-labs/on-chain-effects` ^0.2.0, indexer-v3 cross_chain_deposit table). Build:

- `sweeper-bot/src/inbound-flow.ts` (BRIDGED spoke→hub)
- `sweeper-bot/src/outbound-flow.ts` (BRIDGED hub→spoke buffer replenishment)
- `sweeper-bot/src/bridge-client.ts` (CCTP + Stargate routing)
- `sweeper-bot/src/water-marks.ts` (3×/1× rolling 24h)
- Dockerfile + docker-compose entry
- Prom metrics + SLO alerts

### F4. M10 Phase 2 frontend

Per §7. Build deposit source-chain selector, withdraw target-chain selector (liquidity-aware), portfolio per-chain breakdown, pending-state polling UX, refund flow, e2e specs.

### F5. SPOKE_NATIVE deposit verification

Only BRIDGED (USDC) tested in M8 burn-in. SPOKE_NATIVE (XSGD on Base, IDRX on Polygon, etc.) requires:

1. Register asset classification on spoke gateway + vault (`classification == 2` in payload)
2. Fund vault with mock SPOKE_NATIVE token
3. Trigger deposit, verify hub-side `BalanceLedger.Credited` + `ChainLiquidity[asset][sourceChainId]` increment

Mechanically same code path as BRIDGED. Decisive test for the M10 SPOKE_NATIVE withdrawal selector.

### F6. Hub→Spoke withdrawal burn-in

Full `WithdrawalRegistry` → LZ → `SpokePayout` round-trip not exercised in M8. Requires:

1. User initiates withdrawal request via `WithdrawalRegistry.requestWithdrawal`
2. Backend authorizes (`WithdrawalRegistry.authorize`)
3. LZ message dispatched to target spoke's `SpokePayout`
4. `SpokePayout.release(user, asset, amount)` releases from BRIDGED buffer (or SpokeVaultStable for SPOKE_NATIVE)
5. Backend `markCompleted` on LZ ack

SpokePayout is upgraded with the same `allowInitializePath` + `lzReceive` fixes (Bugs 3, 4) — path SHOULD work but needs explicit burn-in.

### F7. Polygon Amoy spoke deploy

Deferred at M8 burn-in time:
- Insufficient testnet POL faucet output
- Unstable Polygon RPC at the time

Add when:
- Polygon testnet POL is plentiful
- Polygon RPC is reliable (Alchemy/QuickNode)

Run phases B + C + D again with `SPOKE_POLYGON_*` enabled in `.env.chains`.

### F8. DVN configuration

Per C7.

- **Testnet:** 1-of-1 LayerZero Labs DVN — already configured on Base + Arb pathway. Apply same to Eth + BNB + Polygon pathways as those spokes come online.
- **Mainnet:** 2-of-2 (LayerZero Labs + Google Cloud) across all pathways. Both DVNs confirmed available on all 5 target chains.
- **3-of-3 liquidation pathway:** Phase 2 follow-up (no liquidation engine in Phase 1).
- Create `ConfigureDVN.s.sol` to call `OAppOptionsType3.setEnforcedOptions` + `EndpointV2.setConfig` per pathway. Hard-code config in `config/layerzero-dvn.json`.

### F9. Reorg handling on real testnet reorgs

Indexer-v3 reorg handling verified only against synthetic block-hash divergence in unit tests. Real testnet reorgs (Eth Sepolia has the deepest finality at N=64) untested.

Need to wait for or trigger a real reorg on a testnet, then verify indexer correctly:
1. Detects the divergence
2. Deletes rows with `block > fork-point`
3. Replays from fork point
4. Reapplies eager-path stamps idempotently

### F10. Future Solver Fast-Fill activation

Per `phase-1-cross-chain-balance-ledger.md` "Future: Solver Fast-Fill Layer". When activated:

| | Phase 1 (no solver) | Future (with solver) |
|---|---|---|
| Cross-chain deposit latency | ~30s–2min (LZ confirmation) | ~3s (solver front-run) |
| Capital required | Zero | 20% of peak 24h deposit volume per spoke |
| Services to operate | Sweeper only | Solver Service + Sweeper with reimbursement |
| Complexity | Lower | Higher (capital management, reimbursement tracking) |

**When to revisit:**
- Cross-chain deposit volume exceeds threshold where 30s–2min latency hurts competitive position
- Protocol has sufficient capital or external solver partners willing to front liquidity
- User feedback indicates deposit latency is a pain point

**What's already built (dormant):** `HubIntentSettler.fillFor`, `HubIntentSettler.markNoFill`, `SettlementLedger.register/match`, `HubIntentSettler.releaseToSolver`. All have passing tests.

**What to build when ready:**
1. `solver-service/` new Node/TS service: `deposit-watcher.ts`, `deposit-validator.ts`, `filler.ts`, `no-fill-keeper.ts`, `capital-manager.ts`. Bootstrap: $50k per-spoke cap, team-funded hot wallet.
2. Extend Sweeper `inbound-flow.ts` to call `SettlementLedger.match(depositId, bridgedAmount)` after bridging, eagerly apply `cross_chain_deposit.state = SETTLED` + solver reimbursement bookkeeping.
3. DB schema: add `solver BYTEA`, `filled_at TIMESTAMPTZ`, `reimbursed_at TIMESTAMPTZ` to `cross_chain_deposit`. State machine adds `FILLED` between `INITIATED` and `CREDITED`.
4. Activate dormant `settlement-ledger.processor.ts` in indexer-v3; update `hub-intent-settler.processor.ts` to handle `SolverFillRegistered` events.
5. Switch refund path from timeout-based to solver-aware proof-of-non-fill via `markNoFill`.

**Solver reimbursement destination:** Solver EOA directly (not BalanceLedger entry). Keeps BalanceLedger clean of operational accounts.

### F11. Mainnet LZ endpoint addresses + EID config

`bin/lz-testnet-config.sh` covers testnet only. Mainnet equivalents needed:

| Chain | LZ V2 Endpoint (mainnet) | EID |
|---|---|---|
| Arbitrum One | TBD | TBD |
| Base | TBD | TBD |
| Ethereum | TBD | TBD |
| BNB Chain | TBD | TBD |
| Polygon | TBD | TBD |

Add `bin/lz-mainnet-config.sh` and update `script/Configure*.s.sol` to source from env.

---

## 9. Cross-Chain-Adjacent Hub Decisions (for context)

These decisions were made during the cross-chain Phase 1 effort but apply on hub-only too. They live in their own source docs and are checklisted in `hub-only-launch-plan.md`. Listed here so the cross-chain doc cross-references them cleanly when the deferred work resumes:

- **Collateral lifecycle (P1b-explicit model)** — `MatchData.collateralAssets[]` carries explicit borrower flag requests; `Centuari.settleMatch` flags only what was requested; `Centuari.repay` never touches flags; `CollateralManager` is the single unflag seam with 24h flag-lock + RiskModule gate. Reference: `collateral-loophole-fix-plan.md` P1b-explicit section.
- **Collateral frontend implementation** — queue-only flag + dequeue-or-submit unflag + 24h countdown + emergency direct flag for HF rescue. Reference: `collateral-frontend-implementation.md`.
- **Order lock lifecycle (Phase 1A + 1B, shipped 2026-05-10)** — settlement-engine writeback + backend HF buffer + FILLED-but-unsettled match counting. Reference: `order-lock-lifecycle-followups.md` for the two known issues (cancel-during-match race; stuck-PENDING sweeper).
- **HF buffer + pending-borrow-match counting** — backend `risk.borrow_buffer_bps` (default 100) + per-collateral aggregation. Hub-only feature.

---

## 10. References & Provenance

| Section | Source |
|---|---|
| §1, §2 | `phase-1-cross-chain-balance-ledger.md` Context + C1–C11 |
| §3.1–3.3 | `phase-1-cross-chain-balance-ledger.md` Module 4 + post-M8 patches |
| §3.4 | `phase-1-cross-chain-balance-ledger.md` Module 5 + `m8-burn-in-completion.md` (Bugs 1–4) |
| §3.6 | `phase-1-cross-chain-balance-ledger.md` Module 5 §"implementation deviations" |
| §4.1 | `phase-1-cross-chain-balance-ledger.md` Module 8 |
| §4.2 | `phase-1-cross-chain-balance-ledger.md` Module 7 |
| §4.3 | `phase-1-cross-chain-balance-ledger.md` Module 9 backend portion |
| §4.5 | `phase-a-settlement-engine-eager-writes.md` |
| §5 | `m8-burn-in-completion.md` (entire doc) |
| §6 | `m8-burn-in-runbook.md` (entire doc) |
| §7 | `phase-1-cross-chain-balance-ledger.md` Module 10 |
| §8 F1–F11 | `m8-burn-in-completion.md` "Follow-up tasks" + `phase-1-cross-chain-balance-ledger.md` "Future" + "What's NOT verified" |
| §9 | Hub-only cross-references — see `hub-only-launch-plan.md` for active checklists |

**Token × Chain Matrix** (M5/M7/M8/M9/M10 single source of truth):

| Token | Arbitrum (Hub) | Base | Ethereum | BNB | Polygon |
|---|---|---|---|---|---|
| USDC | HUB_DIRECT | CCTP | CCTP | STARGATE | CCTP |
| USDT | HUB_DIRECT | STARGATE | STARGATE | STARGATE | STARGATE |
| WETH | HUB_DIRECT | STARGATE | STARGATE | SPOKE_NATIVE | SPOKE_NATIVE |
| WBTC | HUB_DIRECT | — | STARGATE | — | — |
| XSGD | SPOKE_NATIVE | SPOKE_NATIVE | — | — | SPOKE_NATIVE |
| IDRX | — | SPOKE_NATIVE | — | SPOKE_NATIVE | — |
| XAUT | — | — | SPOKE_NATIVE | — | — |
| SLVon / NVDAon / AAPLon / TLTon | — | — | SPOKE_NATIVE | SPOKE_NATIVE | — |

Stored as `smart-contract-revamp/config/token-chain-matrix.json` (the machine-readable source).

**Things explicitly NOT in Phase 1 (deferred to later phases):**

- YieldRouter + Aave/Compound/Morpho adapters (Phase 5B)
- AssetBehaviorRegistry (Phase 2A)
- RiskModule + LiquidationEngine (Phase 2B)
- CentuariEndpoint + HSM signing + SettlementBatch (Phase 3A)
- Auto-Rollover / Auto-Refinance / Maturity Engine (Phase 4)
- pCBT vault (Phase 4E)
- On-chain `placeOrder` via Phase 6 `CentuariRouter`
- CentuariRouter + Credit Kit (Phase 6)
- RWA attestation (Phase 2A)
- CBT secondary market / early exit (Phase 5C)
- Keeper Bot infrastructure (Phase 8C)
- Solver Service / fast-fill layer (deferred — see §9 F10)

---

## Resuming this work

When hub-only launch is shipped + stable, picking the cross-chain work back up should look like:

1. Read this doc end-to-end.
2. Confirm hub-only-launch-plan.md decisions don't conflict with cross-chain expectations (token allowlist, mainnet token×chain matrix, indexer hub-only config).
3. Execute §8 in dependency order: F1 + F2 unblock all spokes → F3 Sweeper Bot → F4 frontend Phase 2 → F5/F6/F7 burn-in remaining paths → F8 DVN config → F9 reorg verification → F11 mainnet LZ config → F10 solver (only when justified).
