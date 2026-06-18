# M8 Burn-in — Completion Handoff

> **2026-05-14 — consolidated into [`cross-chain-launch-plan.md`](../cross-chain-launch-plan.md) §5.** The summary, the 5 bugs, the verification evidence, and the follow-up PRs all live there now. This doc is kept as the deep reference. Cross-chain launch is deferred behind the hub-only launch ([`hub-only-launch-plan.md`](../hub-only-launch-plan.md)).

> **Status:** ✅ DONE (2026-05-06). End-to-end LZ V2 spoke→hub round-trip verified live on testnet. 5 contract bugs surfaced + patched. Indexer-v3 captured all 3 critical processors against real events.
>
> **Audience:** anyone reviewing M8 completion or merging the contract patches through normal review.

## TL;DR

- **Indexer-v3 substrate** was already feature-complete (235/235 unit tests pass, 10 processors, hub-only burn-in passed 2026-04-21).
- **Spoke + LZ + balance-ledger processors** are now verified against real events on Arb Sepolia (hub) + Base Sepolia (spoke).
- **5 real contract bugs** surfaced during burn-in (not caught by unit tests because the unit-test MockLZEndpoint had the same bugs as the real contracts — a textbook example of mocks mirroring buggy implementations). All 5 are patched and the patched contracts are upgraded on testnet.
- **Net new tooling:** orchestrator + Foundry scripts + runbook + this doc.

## End-to-end verification evidence

The `0x2afaac2d…626483` deposit made the full round trip:

| Step | Chain | Block | Tx | Indexer row state |
|---|---|---|---|---|
| `SpokeDepositGateway.DepositInitiated` | Base Sepolia (40245) | 41,074,237 | `0x28859d20af597b35547b997639718b9eb54918599b4b18f9a5b437ce5f74052c` | `cross_chain_deposit` row INSERTED, `state=INITIATED` |
| LZ V2 relay | (off-chain) | — | — | — |
| `HubIntentSettler.DepositConfirmed` | Arb Sepolia (40231) | 265,677,851 | `0x8f99a27a0f311f65457008465da4892aa3c98aeec1999622327c8060357aac56` | Same row UPDATED, `state=CREDITED`, `credited_tx` stamped |
| `BalanceLedger.Credited` | Arb Sepolia | 265,677,851 | (same tx, same block) | `user_balance` row INSERTED, `available=1,000,000` for user `0x477dcb9AE…EfE1` / asset `0x51138a4bf…e70b3` |

End-to-end latency: ~22 min (LZ V2 testnet, low-priority free pathway).

**Processors verified against live events:**
1. ✅ `spoke-deposit-gateway.processor.ts` (DepositInitiated → cross_chain_deposit)
2. ✅ `hub-intent-settler.processor.ts` (DepositConfirmed → cross_chain_deposit credited)
3. ✅ `balance-ledger.processor.ts` (Credited → user_balance.available)

**Centuari positions processor** (`MarketCreated` / `BorrowPositionCreated` / `LendPositionCreated` / `Repaid` / `LendPositionWithdrawn`) was already covered by the hub-only burn-in on 2026-04-21 — it processes Arb Sepolia events with no cross-chain dependency.

## Contract bugs found + patched during burn-in

All bugs are real production issues, not testnet-only. Each was upstream of the previous: you can only see bug N once bug N-1 is fixed.

### Bug 1 — `SpokeDepositGateway` empty LayerZero options

**File:** [src/core/cross-chain/spoke/SpokeDepositGateway.sol](../../src/core/cross-chain/spoke/SpokeDepositGateway.sol) — `_lzSend` AND `quoteDeposit`.

**Symptom:** `LZ_ULN_InvalidWorkerOptions(uint256)` revert at the first byte of options blob during `endpoint.quote()`. Every deposit attempt reverted before tokens could even be approved.

**Root cause:** Both functions constructed `MessagingParams` with `options: bytes("")`. LZ V2's UltraLightNode library requires non-empty Type-3 options that include an executor `lzReceive` gas hint.

**Fix:** Added `bytes private constant DEFAULT_LZ_OPTIONS = hex"00030100110100000000000000000000000000030d40";` (Type-3 + ExecutorLzReceiveOption with 200,000 gas) and reference it in both call sites.

**Production impact:** ALL deposits on ALL spokes blocked until patched. Same bug applies to Eth/BNB/Polygon spoke contracts (only Base was patched + upgraded for burn-in; the rest need the same upgrade for production).

### Bug 2 — `SpokeVaultStable.setGateway` / `setPayout` never called by setup scripts

**Files:** Setup scripts under `bin/` and `script/`.

**Symptom:** `Unauthorized()` revert from `SpokeVaultStable.depositBridged` because the vault's `_gateway` was zero. Caller (`SpokeDepositGateway`) failed the `onlyGateway` modifier check.

**Root cause:** The post-deploy wiring scripts (`deploy-spoke.sh`, `ConfigureSpokeForM5.s.sol`) registered LZ peers but never registered the gateway/payout authorities on the vault.

**Fix (interim, manual):** `cast send vault setGateway(gateway)` and `cast send vault setPayout(payout)` for Base Sepolia. Same wiring needed on Eth/BNB/Polygon for production.

**Better fix (✅ DONE 2026-05-09):** `script/ConfigureSpokeForM5.s.sol` now calls `vault.setGateway(gatewayAddr)` and `vault.setPayout(payoutAddr)` between the LZ peer wiring and asset classification (new section 3). Future spoke deploys via `bin/run-all-cross-chain.sh` phase C are wired automatically.

### Bug 3 — `HubIntentSettler` + `SpokePayout` missing `allowInitializePath()`

**Files:** [src/core/cross-chain/HubIntentSettler.sol](../../src/core/cross-chain/HubIntentSettler.sol), [src/core/cross-chain/spoke/SpokePayout.sol](../../src/core/cross-chain/spoke/SpokePayout.sol).

**Symptom:** LZ scanner reported `BLOCKED: Not Initializable` for every cross-chain message. DVN never even started verification.

**Root cause:** LZ V2's `EndpointV2._initializable()` calls `receiver.allowInitializePath(origin)` to decide whether a brand-new `(srcEid, sender, nonce)` tuple can establish a delivery path. If the receiver doesn't implement the method (or reverts), every first-time pathway is blocked. Our custom OApps didn't inherit OAppCore so the method was missing.

**Fix:** Added to both contracts:
```solidity
function allowInitializePath(Origin calldata origin) external view returns (bool) {
    bytes32 expected = _trustedRemotes[origin.srcEid]; // or _peers on SpokePayout
    return expected != bytes32(0) && origin.sender == expected;
}
```

### Bug 4 — `lzReceive` arg order doesn't match LZ V2 standard

**Files:** [src/core/cross-chain/HubIntentSettler.sol](../../src/core/cross-chain/HubIntentSettler.sol), [src/core/cross-chain/spoke/SpokePayout.sol](../../src/core/cross-chain/spoke/SpokePayout.sol), [test/mocks/MockLZEndpoint.sol](../../test/mocks/MockLZEndpoint.sol).

**Symptom:** LZ scanner: `FAILED — Executor transaction simulation reverted` with empty revert data. Multiple retries all failed identically.

**Root cause:** Our `lzReceive` was declared as:
```solidity
function lzReceive(Origin, address /*receiver*/, bytes32 /*guid*/, bytes message, bytes /*extraData*/)
```
LZ V2's `ILayerZeroReceiver` standard is:
```solidity
function lzReceive(Origin, bytes32 guid, bytes message, address executor, bytes extraData) payable
```
The function selectors differ (`0x...` vs `0x13137d65`). The endpoint's calldata couldn't ABI-decode against our function — the `bytes32` guid lined up where we expected `address`, the dynamic `bytes` offset lined up where we expected `bytes32`, etc. Result: silent revert with empty data.

**Why unit tests didn't catch it:** `test/mocks/MockLZEndpoint.sol` was written to match the wrong signature, so the wrong-signature contract called the wrong-signature mock — both agreed and tests passed. **Mock-mirror-bug** anti-pattern.

**Fix:** Swapped arg order in both contracts AND in MockLZEndpoint AND in 10 test call sites (`HubIntentSettler.confirmDeposit.t.sol`, `SpokePayout.t.sol`). 235/235 tests pass post-fix.

## On-chain upgrades performed

| Contract | Chain | Old impl | New impl |
|---|---|---|---|
| `SpokeDepositGateway` | Base Sepolia (84532) | initial deploy | `0x3788195123B6C9E14DCB4E8d3de263C3867AEC70` (LZ options fix) |
| `HubIntentSettler` | Arb Sepolia (421614) | initial deploy → `0x63a19A163f268dC8bAd64eDdDF19bf39FE555266` (allowInitializePath only) | `0x3a1eEd829949049Fd8227D547458b4aEd99D9FCd` (allowInitializePath + lzReceive sig fix) |
| `SpokePayout` | Base Sepolia | initial deploy | `0x89f32b5f659a71c16DA01Be808059e787e472217` (allowInitializePath + lzReceive sig fix) |

ProxyAdmin owners are still the burn-in deployer. Storage layouts unchanged (only function bodies / signatures changed).

**Same patches needed on the other deployed spokes** before any cross-chain traffic flows there:
- Eth Sepolia: SpokeDepositGateway + SpokePayout
- BNB Testnet: SpokeDepositGateway + SpokePayout

(Polygon Amoy was deferred — no spoke contracts deployed there yet.)

## New tooling delivered (all under [smart-contract-revamp/](..))

| File | Purpose |
|---|---|
| [bin/run-all-cross-chain.sh](../../bin/run-all-cross-chain.sh) | Master orchestrator. 6 resumable phases (A hub deploy → B spoke deploys → C spoke wiring → D hub wiring → E unified summary → F indexer env). `--phase=` to run subsets. Idempotency markers + dry-run + private-key redaction. |
| [bin/lz-testnet-config.sh](../../bin/lz-testnet-config.sh) | Sourceable bash with verified LZ V2 endpoint addresses + EIDs for all 5 testnets. |
| [script/ConfigureSpokeForM5.s.sol](../../script/ConfigureSpokeForM5.s.sol) | Mirror of `ConfigureHubForM5.s.sol`. Sets spoke-side LZ peers + BRIDGED/SPOKE_NATIVE asset classifications on the gateway and vault. |
| [script/BurnInSpokeDeposit.s.sol](../../script/BurnInSpokeDeposit.s.sol) | Burn-in trigger: approve + `quoteDeposit` + `deposit{value: fee}`. Reads SPOKE_GATEWAY / BURN_IN_ASSET / BURN_IN_AMOUNT from env. |
| [docs/m8-burn-in-runbook.md](m8-burn-in-runbook.md) | Phase 0 prereqs runbook (key generation, RPC URLs, faucets, sanity checks) + phases A–G overview. |
| [docs/m8-burn-in-completion.md](m8-burn-in-completion.md) | This doc. |

## Follow-up tasks (PRs to ship through normal review)

These are the production-relevant fixes. Each can be a focused PR.

1. **PR: SpokeDepositGateway LZ options fix** — port the `DEFAULT_LZ_OPTIONS` constant + the two call-site updates. Apply on all 4 spoke chains via a `bin/upgrade-spoke-gateway.sh` helper.
2. **PR: HubIntentSettler + SpokePayout `allowInitializePath`** — small, low-risk method addition. Plus `lzReceive` signature rewrite to match LZ V2 `(Origin, bytes32 guid, bytes message, address executor, bytes extraData)`.
3. **PR: MockLZEndpoint signature fix + test rewrites** — bundle with #2 since the tests are coupled.
4. ✅ **DONE 2026-05-09 — ConfigureSpokeForM5 wires `vault.setGateway` + `vault.setPayout`.** Section 3 of the script now registers the vault authorities; closes the missing-setup hole for fresh deploys.
5. **PR: orchestrator polish** — the `bin/run-all-cross-chain.sh` had several iterations during burn-in (skip-spoke handling, idempotent retries, pipefail, env var name mapping for `SPOKE_ETHEREUM_*`). Clean up + add unit tests if any.

## Indexer-v3 state at completion

- 4 ChainWatchers tailing live (HUB Arb Sepolia, SPOKE_BASE, SPOKE_ETHEREUM, SPOKE_BNB). POLYGON deferred.
- `cross_chain_deposit` table contains 4 INITIATED rows + 1 CREDITED row (the burn-in deposit #4).
- 3 older INITIATED deposits remain stuck because their LZ messages were sent BEFORE the contract patches; LZ executor doesn't retry simulations that already definitively failed pre-patch. They could be manually re-driven or just ignored — they're stale test data.
- All processors stamp `applied_by_tx_hash` / `applied_by_log_index` / `applied_by_block_hash` per the C10 idempotency contract.

## What's NOT verified by this burn-in

- **Spoke→Hub `SPOKE_NATIVE` deposit path** — only BRIDGED (USDC) was tested. SPOKE_NATIVE (XSGD on Base, IDRX on Polygon, etc.) requires registering the asset classification + funding the vault. Mechanically the same code path as BRIDGED, just with `classification == 2` in the payload.
- **Hub→Spoke withdrawal path** — `WithdrawalRegistry` → LZ → `SpokePayout` was not exercised. Requires withdrawal request + buffer replenishment. SpokePayout is upgraded with the same fixes, so the path SHOULD work but needs its own burn-in.
- **Centuari positions processor on a fresh post-orchestrator deploy** — handled by the existing 2026-04-21 hub-only burn-in.
- **Polygon Amoy spoke** — deferred (insufficient testnet POL for deploy at the time, plus Polygon RPC was unstable). Add when ready.
- **Reorg handling on real testnet reorgs** — only verified in unit tests with synthetic block-hash divergence.

## Verification commands (anyone can re-run)

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
# Look for DepositConfirmed event from HubIntentSettler.

# 4. Verify on LayerZero scan
# https://testnet.layerzeroscan.com/tx/0x28859d20af597b35547b997639718b9eb54918599b4b18f9a5b437ce5f74052c
# Status: DELIVERED. Source Base Sepolia → destination Arb Sepolia.
```

## M8 sign-off

- **Spec:** `docs/phase-1-cross-chain-balance-ledger.md` § Module 8 (now marked ✅ DONE 2026-05-06).
- **Critical-path unblock:** M9 matching-engine `BalanceLedgerClient` and M10 frontend deposit/withdraw chain selectors are now safe to wire up — they can rely on the indexer's REST API for balance state.
- **Sweeper Bot (M7)** can now build against the verified `apply-on-chain-effect` shared package + the now-tested processor schema.
