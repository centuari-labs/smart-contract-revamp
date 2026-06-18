# Frontend — Collateral Flag UX & Hooks

> **2026-05-14.** Frontend collateral toggle work (Track B in [`hub-only-launch-plan.md`](../hub-only-launch-plan.md)) is mostly shipped — only E2E unblock (Privy SDK 3.10 JWT) + "Remove as collateral" button + 24h countdown remain. The B3 launch decision (RiskModuleStub vs real RiskModule) lives in `hub-only-launch-plan.md` §5. Cross-chain UI implications are summarized in [`cross-chain-launch-plan.md`](../cross-chain-launch-plan.md) §7.

## Status

| Step | Status | Notes |
|---|---|---|
| Phase 1 — `CollateralManager` dual-function (operator + direct caller) | 🟢 SHIPPED | `flag(asset)` / `unflag(asset)` direct entry points alongside `flagFor(user, asset)` / `unflagFor(user, asset)`. Tested 26/26. Upgrade script `script/UpgradeCollateralManager.s.sol` ready. Testnet upgrade pending. |
| Phase 2 — backend-v2 queue-only flag, dequeue-or-submit unflag | 🟢 SHIPPED | `POST /collateral/flag { asset }` always queues; `POST /collateral/unflag { asset }` dequeues if queue-only, else `readContract(canUnflag)` short-circuit then operator-key `unflagFor`. Redis 10/wallet/24h rate limit, 20-row queue cap. Legacy `PUT /portfolio/is-collateral` deleted. |
| Phase 3 — settlement-engine queue read at settle + receipt-event DELETE | 🟢 SHIPPED | `pending_collateral_flags` read for distinct borrowers; encoded into `MatchData.collateralAssets` per match; eager DELETE on `CollateralFlagSet` events from receipt logs. |
| Phase 4 — indexer-v3 tail DELETE in `balance-ledger.processor.ts` | 🟢 SHIPPED | Idempotent peer DELETE alongside backend dequeue + settlement-engine eager. Covers direct-caller events + missed eager writes. |
| **Phase 5 — frontend hooks + UI + emergency direct flag** | 🟢 **SHIPPED** | Three hooks live (`use-flag-collateral`, `use-flag-collateral-direct`, `use-unflag-collateral`); `CollateralBadge` + `CollateralActions` in `data-table-assets.tsx`; `centuari-hf-banner.tsx` + `use-asset-as-collateral-dialog.tsx`. Backend `pendingCollateralFlag` field + `POST /collateral/{flag,unflag}` endpoints live. **One follow-up still open:** E2E suite `e2e/collateral-toggle.spec.ts` has 8 scenarios but is `test.skip()`-gated via `preflightOrSkip()` because Privy SDK 3.10.0 rejects stub JWTs — see "Privy auth re-capture cadence" follow-up below. |

This is a living document. Pick it up when the frontend stream is unblocked; extend / correct / annotate freely.

## Context

The on-chain `usedAsCollateral` flag closes a loophole where a user could bypass the backend HF check by calling `WithdrawalRegistry.requestWithdrawal` directly (see `collateral-loophole-fix-plan.md`). The off-chain rewrite (Phases 1–4) gives users two ways to flag collateral:

1. **Default — backend queue.** No wallet signature, no gas. The user toggles in the UI; backend enqueues to `pending_collateral_flags`. The flag actually lands on-chain at the next match settlement when settlement-engine reads the queue, encodes `MatchData.collateralAssets`, and `Centuari.settleMatch` calls `markCollateral`.
2. **Emergency — user-signed direct.** For pre-liquidation HF rescue. Frontend calls `CollateralManager.flag(asset)` directly via wagmi/Privy. User signs, user pays gas. Indexer-v3's tail picks up the `CollateralFlagSet` event and stamps `user_balance.used_as_collateral=true` immediately.

Unflag is always backend-mediated, with two internal paths:

- **Dequeue** — if asset is queue-only, backend deletes the queue row and returns `{ dequeued: true }`. No on-chain action.
- **On-chain unflag** — if asset is on-chain flagged, backend pre-checks `RiskModule.canUnflag` (Phase 1 stub returns `false` unconditionally → 409 immediately, no gas), then submits `CollateralManager.unflagFor(user, asset)` with the operator key.

**HF rule.** Frontend HF computation reads only `user_balance.used_as_collateral=true` rows from the indexer. Queue-only flags do **not** count toward HF — that matches what a liquidator sees and prevents a false-safety footgun.

## Backend API contract

All endpoints under `POST /collateral/*` require Privy JWT auth via `AuthGuard`. Wallet is extracted via the `@Wallet()` decorator.

### `POST /collateral/flag`

```
Request:  { asset: "0x…" }
Response (success): { queued: true }
Response (cap):     400 { code: "COLLATERAL_LIMIT_EXCEEDED", currentCount: number, cap: 20 }
Response (rate):    429 { code: "RATE_LIMITED", retryAfterSeconds: number }
```

- **Always queues.** Never submits on-chain. Idempotent — re-issuing for the same `(wallet, asset)` is a no-op.
- The 20-row cap protects settlement gas budget. The 10/wallet/24h Redis rate limit applies to all `/collateral/*` writes combined.

### `POST /collateral/unflag`

```
Request:  { asset: "0x…" }
Response (queue-only):  { dequeued: true }
Response (on-chain ok): { applied: true,  txHash: "0x…" }
Response (on-chain bad): { applied: false, reason: "args_mismatch" | "event_missing" | "receipt_reverted" | "already_stamped" }
Response (rate):  429 { code: "RATE_LIMITED",       retryAfterSeconds: number }
Response (HF):    409 { code: "WOULD_MAKE_UNHEALTHY" }
Response (lock):  409 { code: "FlagLockActive",     unlocksAt?: string } (uint64 seconds)
Response (other): 409 { code: "NOT_FLAGGED" } (defensive — should not surface in normal use)
```

- **Branch on response shape**, not on HTTP status alone — `{ dequeued: true }` and `{ applied: true, txHash }` are both 200, but the UX should differ (instant clear vs. tx-link toast).
- 429 is shared with the flag endpoint — either action consumes from the same wallet bucket.

## Direct-call contract surface (emergency flag)

Frontend calls `CollateralManager` directly via wagmi for the urgent path. **Address comes from indexer config / shared deployment JSON, not from a backend endpoint.** Reads from `smart-contract-revamp/deployments/deploy-arb_sepolia-latest.json` after each contract deploy, surfaced via `frontend-revamp/src/lib/chain-config.ts` (or equivalent).

### `flag(address asset)`

```solidity
function flag(address asset) external whenNotPaused;
```

- `msg.sender` is the user; no operator gate.
- Always succeeds (no policy gates — flagging only improves HF).
- Emits `CollateralFlagSet(writer=msg.sender, user=msg.sender, asset, used=true, flaggedAt)`.
- Repeat-mark is idempotent at the `BalanceLedger` level — `flaggedAt` is **not** refreshed on second call.
- Indexer-v3 tail picks up the event within ~tens of seconds and:
  - Stamps `user_balance.used_as_collateral=true` + `flagged_at` + the four `applied_by_*` columns.
  - DELETEs any matching `pending_collateral_flags` row (so a queued duplicate doesn't re-apply at the next settlement).
- Frontend should optimistically update the badge to "Pending on-chain confirmation" immediately after the wallet returns `txHash`; refetch portfolio when the indexer catches up.

### `unflag(address asset)` (NOT recommended for app use — informational only)

```solidity
function unflag(address asset) external whenNotPaused;
```

- Same policy seam as `unflagFor`: `NotFlagged` → `FlagLockActive(unlocksAt)` → `RiskModule.canUnflag` → `unmarkCollateral`.
- Phase 1 stub `canUnflag` returns `false` unconditionally → every direct unflag reverts `WouldMakeUnhealthy` until Phase 2 RiskModule lands.
- The frontend should NOT add a "Force unflag" affordance for this. The backend-mediated unflag (with the off-chain `readContract(canUnflag)` short-circuit) gives users a friendlier error path and is rate-limited; routing direct-signed unflag through wagmi adds gas and provides no benefit.
- Document the existence of this direct path in copy ("Trustless: you can always unflag via the contract directly if our backend is down") but don't surface a button.

## UI states

### Three-state badge per portfolio asset row

The portfolio response from `GET /portfolio/:user` (or `GET /balance/:user`) needs `pendingCollateralFlag: boolean` per asset. Sub-task during implementation: extend either indexer-v3's `/portfolio/:user` route (preferred — `LEFT JOIN pending_collateral_flags ON …`) or backend-v2's portfolio service to merge that field. Frontend reads:

```ts
type AssetRowState =
  | { kind: "none" }                         // both flags false
  | { kind: "pending" }                      // pending_collateral_flag=true,  used_as_collateral=false
  | { kind: "onchain"; flaggedAt: number };  //                                used_as_collateral=true (flagged_at in seconds)
```

| State | Badge | Tooltip / sublabel | Counts toward HF? |
|---|---|---|---|
| `none` | — | — | — |
| `pending` | Yellow "Pending" | "Will count as collateral when your next borrow settles. To use it now, click 'Flag now'." | **No** |
| `onchain` (locked, < 24h) | Green "Collateral" + countdown | `flagged_at + 24h - now`, ticking | **Yes** |
| `onchain` (lock expired) | Green "Collateral" | (countdown hidden) | **Yes** |

### Buttons per asset row

| Button | Visible when | Action | Confirmation modal |
|---|---|---|---|
| **"Flag as collateral"** | `kind: "none"` | `useSetCollateral.mutate({ asset })` → backend queues | Brief — "Will apply at your next match settlement. Free, no signature needed." |
| **"Flag now (urgent)"** | `kind: "none"` (secondary action below the cheap Flag) | wagmi `writeContract` → `CollateralManager.flag(asset)` | Strong — "This requires a wallet signature and gas payment to flag immediately on-chain. Use only if you're at risk of liquidation. The cheap 'Flag' option will apply at your next match settlement." |
| **"Remove pending"** | `kind: "pending"` | `useUnflagCollateral.mutate({ asset })` → backend dequeues → `{ dequeued: true }` | Brief — "This removes the queued flag. No on-chain action." |
| **"Remove as collateral"** | `kind: "onchain"` (lock expired only — disabled while countdown > 0) | `useUnflagCollateral.mutate({ asset })` → backend submits `unflagFor` | Important — "Phase 1 will reject this while you have any debt. You may need to repay first. Subject to a 5/wallet/24h rate limit." |

### HF banner

Compute HF from on-chain `used_as_collateral=true` rows only. **Audit existing helpers** under `frontend-revamp/src/hooks/` and `src/lib/` — if any read the `pendingCollateralFlag` field for HF math, that's a bug to fix.

When HF approaches a danger threshold (recommended: HF < 1.2), surface a yellow banner above the portfolio with copy: "Your position is approaching liquidation. Consider flagging additional assets as collateral to improve your health factor." Promote any **`kind: "none"`** assets that the user holds with a "Flag now (urgent)" CTA — same wagmi direct-call path. The cheap queued flag is misleading here because it won't take effect until the next borrow settlement.

## Hooks to write / rewrite

### `src/hooks/use-set-collateral.ts` — REWRITE

Drop the legacy `PUT /portfolio/is-collateral` call (the endpoint was deleted in Phase 2). Replace with:

```ts
useMutation({
  mutationFn: ({ asset }: { asset: `0x${string}` }) =>
    apiClient.post("/collateral/flag", { asset }),
  onSuccess: () => {
    queryClient.invalidateQueries({ queryKey: ["portfolio"] });
    toast.success("Collateral preference saved. Will apply at your next match.");
  },
  onError: (err) => {
    if (err.code === "COLLATERAL_LIMIT_EXCEEDED") {
      toast.error(`You've queued ${err.currentCount}/${err.cap} collateral flags. Remove some before adding more.`);
    } else if (err.code === "RATE_LIMITED") {
      toast.error(`Too many actions — try again in ${humanizeSeconds(err.retryAfterSeconds)}.`);
    } else {
      toast.error("Couldn't save collateral preference. Try again.");
    }
  },
});
```

### `src/hooks/use-flag-collateral-direct.ts` — NEW

Wraps wagmi for the emergency immediate-flag path. Privy-aware (use the user's connected wallet, not a server wallet).

```ts
const { writeContractAsync } = useWriteContract();

useMutation({
  mutationFn: async ({ asset }: { asset: `0x${string}` }) => {
    const txHash = await writeContractAsync({
      address: collateralManagerAddress,
      abi: collateralManagerAbi,
      functionName: "flag",
      args: [asset],
    });
    // Don't wait for indexer here — return optimistically. Portfolio refetch
    // will reflect the on-chain state once the indexer catches up.
    return { txHash };
  },
  onSuccess: ({ txHash }) => {
    queryClient.invalidateQueries({ queryKey: ["portfolio"] });
    toast.success(
      <a href={`${explorerUrl}/tx/${txHash}`} target="_blank">View tx</a>,
      { description: "Flag landing on-chain. Your HF will update shortly." }
    );
  },
  onError: (err) => {
    if (err.code === 4001) toast.error("You rejected the transaction.");
    else toast.error("Couldn't flag on-chain. Try again or use the cheap option.");
  },
});
```

### `src/hooks/use-unflag-collateral.ts` — NEW

```ts
useMutation({
  mutationFn: ({ asset }: { asset: `0x${string}` }) =>
    apiClient.post("/collateral/unflag", { asset }),
  onSuccess: (response) => {
    queryClient.invalidateQueries({ queryKey: ["portfolio"] });
    if ("dequeued" in response) {
      toast.success("Pending collateral preference removed.");
    } else if ("applied" in response && response.applied) {
      toast.success(<TxLink hash={response.txHash} />);
    } else if ("applied" in response) {
      // applied=false: tx submitted but apply-effect rejected (rare —
      // log and surface the underlying reason for debugging)
      toast.warning(`Unflag couldn't be confirmed: ${response.reason}`);
    }
  },
  onError: (err) => {
    if (err.code === "WOULD_MAKE_UNHEALTHY") {
      toast.error("Repaying debt is required to unflag this collateral.");
    } else if (err.code === "FlagLockActive" && err.unlocksAt) {
      toast.error(`Unlocks at ${formatTimestamp(Number(err.unlocksAt) * 1000)}.`);
    } else if (err.code === "RATE_LIMITED") {
      toast.error(`Too many actions — try again in ${humanizeSeconds(err.retryAfterSeconds)}.`);
    } else {
      toast.error("Couldn't unflag. Try again.");
    }
  },
});
```

## Components to update

### `src/components/centuari-portfolio/`

Per-asset row component renders the three-state badge + the appropriate button(s) per the table above. The countdown for `kind: "onchain"` is a `setInterval` inside a small `useCountdown(flaggedAt + 86_400)` hook; tear down on unmount.

### `src/components/centuari-borrow/centuari-borrow-dialog.tsx`

The `selectedCollaterals` multi-select stays — it's still a per-order convenience for setting collateral preferences alongside placing the borrow. Behind the scenes, when the user submits the borrow:

- Frontend calls `useSetCollateral` for each newly selected asset (idempotent enqueue) **before** calling the order placement endpoint. This ensures the queue is up-to-date before settlement-engine reads it.
- Update the modal copy to: *"Selected assets will be auto-flagged for any future borrow until you remove them. They will be on-chain locked as collateral for at least 24 hours after the match settles. Full repayment does NOT automatically release them — you must explicitly unflag after the 24h lock expires."*

Race note: the order may fill before the queue write commits — see "End-to-end behaviour" → "race window" in `~/.claude/plans/help-me-check-the-rustling-pinwheel.md` (or talk to the Phase 3 implementer). Acceptable in practice — the window is ~tens of milliseconds, and the user's intent at submit time was to flag.

## End-to-end test scenarios (✓ implemented in `frontend-revamp/e2e/collateral-toggle.spec.ts`)

`frontend-revamp/e2e/collateral-toggle.spec.ts` covers:

1. Toggle "Flag as collateral" on an asset → "Pending" badge appears, no wagmi prompt, HF unchanged.
2. Click "Flag now (urgent)" → wagmi popup → user signs → tx confirms → badge transitions Pending → "Collateral" with countdown → HF improves.
3. Toggle "Remove pending" while in `kind: "pending"` → badge clears, no wagmi prompt.
4. Toggle "Remove as collateral" while on-chain (Phase 1 stub) → 409 `WOULD_MAKE_UNHEALTHY` toast immediately, no on-chain tx.
5. Place a borrow with the queued asset → wait for match → Pending → on-chain badge.
6. Spam 11× any flag/unflag combo within 60s → 11th returns 429 `RATE_LIMITED` toast with retry-after seconds.
7. Flag 21 distinct assets via the cheap path → 21st returns 400 `COLLATERAL_LIMIT_EXCEEDED` toast.
8. Race scenario: queue an asset, place a borrow, immediately call `Remove pending` before the match settles → asset still ends up on-chain flagged from the in-flight order; user can on-chain unflag after the 24h lock.

## Phase 4 follow-up — Privy session bypass for e2e tests

The 8 e2e scenarios in `frontend-revamp/e2e/collateral-toggle.spec.ts` are wired and biome-clean, but currently skip at runtime via `preflightOrSkip(page)` because Privy SDK 3.10.0 cryptographically validates session tokens against `auth.privy.io`. Stub JWTs in cookies/localStorage are rejected, so the asset table never renders and there is nothing to assert against. Three remediation paths (documented in detail in the leading comment of the e2e spec file, lines 11–37):

1. **Capture a real Privy session.** One-time interactive login, persist with `await context.storageState({ path: 'e2e/.auth/privy.json' })`, then add `test.use({ storageState: 'e2e/.auth/privy.json' })` to the spec and drop the `test.fixme()` / skip calls. Lowest-touch but the auth artifact has a TTL — re-capture cadence TBD.

2. **Extend the `**/auth.privy.io/**` route mock.** The current fallback mock returns a generic success payload that does not match the SDK's session-refresh response shape. Match the real shape exactly and the SDK will accept stub sessions. Most fragile path — couples test infra to Privy SDK internals.

3. **Window-level test bypass in `useAuthToken.ts`.** Return a stub `getToken()` + `authFetch()` when a window-level test flag is present. Requires touching app code (out of original Phase 4 scope) and explicit approval. Cleanest runtime model but largest surface to gate.

Path (1) is the recommended starting point. None of the three has been picked up yet — needs its own scoped task with explicit approval before implementation. Until then, the e2e spec serves as locked-in regression coverage that activates the moment one of the three paths lands.

## Open questions / future enhancements

Tag with `// TODO(frontend-collateral)` in code as you go.

- **HF threshold for promoting "Flag now".** Recommended HF < 1.2 surfaces a banner. Should we have a finer-grained tier (e.g., < 1.1 makes the cheap option disabled with a "Don't queue — flag now" prompt)? Pull from analytics once we have liquidation events.
- **Mobile UX for the wagmi popup.** Privy embedded wallet vs external wallet: confirm the flow is identical on both. Test on iOS Safari + Android Chrome before shipping.
- **Optimistic UI for direct-flag.** After `writeContractAsync` returns the txHash, show a "Pending on-chain (tx 0x…)" intermediate state in the portfolio row until the indexer catches up. The current plan refetches portfolio + relies on the badge transition; a smoother state machine would be nice.
- **Animation on badge transitions.** GSAP is in the stack — consider a brief pulse when Pending → Collateral lands.
- **Phase 2 RiskModule swap.** When the Phase 1 fail-closed stub is replaced, the `WOULD_MAKE_UNHEALTHY` toast copy should change from "Repaying debt is required to unflag this collateral" to "Your health factor would drop below 1." Conditional on a deploy flag from `chain-config`.
- **`pendingCollateralFlag` exposure in portfolio response.** Decide which service owns it — indexer-v3 LEFT JOIN is the cleanest home, but backend-v2's portfolio service may merge it if cross-service complications arise. Needs a small SQL change either way; not yet implemented.
- **Rate-limit feedback granularity.** Currently the 429 surfaces total wallet bucket. Consider a per-action sub-budget if users hit the cap during legitimate diversification (e.g., 5 flags + 5 unflags vs. one combined 10).
- **Trustless escape hatch UX.** If the backend goes down, users can still call `CollateralManager.unflag(asset)` directly via wagmi (Phase 1 contract). We don't expose a button, but a `<details>` "Advanced: trustless unflag" section in settings could surface the contract address + ABI fragment for users with their own tooling.
- **i18n.** All copy above is English-only; localize at the end.

## References

- `docs/collateral-loophole-fix-plan.md` — original P0–P6 phasing, design rationale (single policy seam, why auto-flag/auto-unflag was wrong).
- `docs/phase-1-cross-chain-balance-ledger.md` — Module 9/10 backend + frontend stream.
- `src/core/collateral/CollateralManager.sol` + `src/interfaces/ICollateralManager.sol` — direct-caller surface.
- `backend-v2/src/collateral/` — service + DTOs + repository.
- `indexer-v3/src/processors/balance-ledger.processor.ts` — tail event handler with queue DELETE.
- `~/.claude/plans/help-me-check-the-rustling-pinwheel.md` — full revised plan with end-to-end behaviour and race analysis.
