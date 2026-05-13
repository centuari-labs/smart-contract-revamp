# M8 Burn-in Runbook — Real Testnet Deploy + Indexer Validation

> **Purpose:** Stand up the Phase 1 cross-chain stack on real testnets (Arbitrum Sepolia hub + 4 spokes), then run indexer-v3 against live events to validate the spoke processors, the LayerZero `HubIntentSettler.confirmDeposit` path, and the Centuari positions processor — closing M8.
>
> **Audience:** You (the operator) running deploys with a fresh testing key, and Claude orchestrating commands per phase.
>
> **Scope:** This document is the canonical instruction set. Each phase pauses for review before the next begins, per the project's phased-execution rule.

## Phases at a glance

Phases A–F are wrapped in a single resumable orchestrator: [bin/run-all-cross-chain.sh](../bin/run-all-cross-chain.sh). Each phase writes a marker file under `.run-all-cross-chain-state/` so reruns skip completed phases.

| Phase | What | Driver | Time | Output |
|---|---|---|---|---|
| **0** | Prereqs — fresh key, RPC URLs, fund wallet, env scaffold | manual | 30–60 min | `.env` + `.env.chains` populated, wallet funded |
| **A** | Hub stack to Arbitrum Sepolia | `run-all-cross-chain.sh --phase=A` (calls `run-all.sh`) | 30–45 min | `deploy-arb-sepolia-latest.json` |
| **B** | Spoke deploys × 4 (+ mock USDC per spoke) | `--phase=B` (calls `deploy-spoke.sh` + `DeployMockTokens`) | 30–45 min | 4× `deploy-spoke-<chainId>-latest.json` |
| **C** | Spoke-side LZ wiring + asset classification × 4 | `--phase=C` (calls new `ConfigureSpokeForM5.s.sol`) | 10 min | Spoke peers + BRIDGED USDC registered |
| **D** | Hub-side LZ wiring | `--phase=D` (calls existing `ConfigureHubForM5.s.sol`) | 10 min | Hub trusted remotes + payout peers registered |
| **E** | Unified `deploy-cross-chain-latest.json` summary | `--phase=E` | <1 min | Aggregated hub + 4 spoke addresses |
| **F** | Auto-populate `indexer-v3/.env` from the unified summary | `--phase=F` | <1 min | Indexer ready to tail 5 chains |
| **G** | Live burn-in: trigger spoke deposit, watch indexer process LZ-confirmed credit, trigger settlement | ✅ DONE 2026-05-06 — see [m8-burn-in-completion.md](m8-burn-in-completion.md) | 30 min | M8 done |

The orchestrator script also accepts `--reset` (clear all phase markers), `--dry-run` (print plan without sending tx), and `--verify` (Etherscan verification).

---

## Phase 0 — Prereqs checklist

Work through every box. **Don't paste any private key, RPC URL, or API key into chat.** Everything goes into local `.env` files that are gitignored.

### 0.1 — Widen `.gitignore` (one-time fix)

The current `smart-contract-revamp/.gitignore` only ignores `.env` exactly. Widen it so `.env.chains` and any other `.env.*` overlay file is automatically ignored.

```bash
cd /Users/hwisea23/Documents/Work/Centuari/Centuari-v2/smart-contract-revamp
# Replace the bare `.env` line with `.env*` (matches .env, .env.chains, .env.local, etc.)
```

Edit `smart-contract-revamp/.gitignore` line 12:

- **Before:** `.env`
- **After:** `.env*`

Repeat the same fix in `indexer-v3/.gitignore` if a `.env.*` overlay pattern is going to be used there too (we won't need overlays in indexer-v3 since it reads all 5 chains from a single `.env`, but the broader pattern is still safer).

Verify:
```bash
git check-ignore -v smart-contract-revamp/.env.chains
# Should print: .gitignore:12:.env*    smart-contract-revamp/.env.chains
```

### 0.2 — Generate a fresh, single-purpose testing key

Use Foundry's built-in keygen. **Run this in a terminal you trust, never in a shared session, and never with screensharing on.**

```bash
cast wallet new
```

Output looks like:
```
Successfully created new keypair.
Address:     0xABCDEF...
Private key: 0x1234567890abcdef...
```

**Immediately:**
- Copy the address into your password manager (you'll paste it into the env file in step 0.3 — that's fine, only the key is sensitive).
- Copy the private key into your password manager. **Never anywhere else.**
- Close the terminal scrollback if you're worried about forensic recovery (`clear && history -c` on bash, or open a fresh tab).

This key will become:
- The deployer of every contract.
- The `OWNER` of every upgradeable proxy (admin functions).
- The `PROXY_ADMIN_OWNER` (controls upgrades).

So if you ever leak it, anyone can rug the deployment. **Use this key for Phase 1 burn-in only. Rotate after.**

### 0.3 — Populate `smart-contract-revamp/.env`

Open `smart-contract-revamp/.env` and ensure these vars are set. RPC_URL gets overridden per phase; leave it pointing at Anvil or Arb Sepolia for now.

```bash
# Existing — leave / set
PRIVATE_KEY=0x<paste your key from 0.2 here, never paste into chat>
RPC_URL=<placeholder; will be overridden per phase>
ETHERSCAN_API_KEY=<your Etherscan multichain key — get one at etherscan.io/myapikey>

# Owner addresses (use the address from 0.2 for all three for the burn-in)
CENTUARI_OWNER=0x<your-deployer-address>
PROXY_ADMIN=0x<your-deployer-address>
BACKEND_OPERATOR=0x<your-deployer-address>
SETTLEMENT_OPERATOR=0x<your-deployer-address>
TREASURY_ADDRESS=0x<your-deployer-address>

# Leave existing CENTUARI_ADDRESS / SETTLEMENT_PROXY / CENTUARI_SETTLEMENT_PLACEHOLDER as-is —
# run-all.sh will write fresh values into deploy-arb-sepolia-latest.json
```

> The deployer-as-everyone shortcut is fine for burn-in. For production you'd split these into separate multisigs.

### 0.4 — Create `smart-contract-revamp/.env.chains`

This is the new per-chain overlay file. It holds RPC URLs for all 5 chains in one place. Phase 1+ commands source this file then set `RPC_URL` from the right per-chain variable.

```bash
cd /Users/hwisea23/Documents/Work/Centuari/Centuari-v2/smart-contract-revamp
touch .env.chains
chmod 600 .env.chains   # owner-only read/write
```

Populate `.env.chains` with content like this (replace placeholders with your actual provider URLs):

```bash
# ============================================================================
# Per-chain RPC URLs for Phase 1 testnet burn-in.
# Get free RPC URLs from Alchemy (recommended for Arb/Base/Eth/Polygon),
# Infura, QuickNode, or the public endpoints listed in chain docs.
# ============================================================================

# Arbitrum Sepolia (chain 421614) — HUB
ARB_SEPOLIA_RPC_URL_HTTP=https://arb-sepolia.g.alchemy.com/v2/<your-key>
ARB_SEPOLIA_RPC_URL_WS=wss://arb-sepolia.g.alchemy.com/v2/<your-key>

# Base Sepolia (chain 84532) — SPOKE
BASE_SEPOLIA_RPC_URL_HTTP=https://base-sepolia.g.alchemy.com/v2/<your-key>
BASE_SEPOLIA_RPC_URL_WS=wss://base-sepolia.g.alchemy.com/v2/<your-key>

# Ethereum Sepolia (chain 11155111) — SPOKE
ETH_SEPOLIA_RPC_URL_HTTP=https://eth-sepolia.g.alchemy.com/v2/<your-key>
ETH_SEPOLIA_RPC_URL_WS=wss://eth-sepolia.g.alchemy.com/v2/<your-key>

# BNB Testnet (chain 97) — SPOKE
# Note: Alchemy doesn't cover BNB testnet. Use QuickNode, Ankr, or the public RPC.
BNB_TESTNET_RPC_URL_HTTP=https://data-seed-prebsc-1-s1.binance.org:8545
BNB_TESTNET_RPC_URL_WS=wss://bsc-testnet.publicnode.com

# Polygon Amoy (chain 80002) — SPOKE
POLYGON_AMOY_RPC_URL_HTTP=https://polygon-amoy.g.alchemy.com/v2/<your-key>
POLYGON_AMOY_RPC_URL_WS=wss://polygon-amoy.g.alchemy.com/v2/<your-key>
```

> **Tip:** an Alchemy free tier (300M compute units / month) easily covers all four Alchemy-supported chains for burn-in volume. BNB testnet needs a different provider — public endpoints work but may rate-limit; QuickNode free tier is more reliable.

### 0.5 — Fund the deployer wallet on all 5 chains

Recommended balances. The hub deploy is heavy (18 contracts behind proxies); spokes are 3 contracts each.

| Chain | Recommended balance | Faucet |
|---|---|---|
| Arbitrum Sepolia | **0.5 ETH** | https://www.alchemy.com/faucets/arbitrum-sepolia or https://sepolia-faucet.pk910.de (PoW, then bridge) |
| Base Sepolia | 0.05 ETH | https://www.alchemy.com/faucets/base-sepolia or https://www.coinbase.com/faucets/base-ethereum-sepolia-faucet |
| Ethereum Sepolia | 0.05 ETH | https://www.alchemy.com/faucets/ethereum-sepolia (GH gated), https://sepolia-faucet.pk910.de (PoW), https://faucet.quicknode.com/ethereum/sepolia |
| BNB Testnet | 0.05 BNB | https://www.bnbchain.org/en/testnet-faucet or https://testnet.bnbchain.org/faucet-smart |
| Polygon Amoy | 0.05 POL | https://faucet.polygon.technology/ |

Faucets often require Twitter/GitHub/email gating to prevent abuse. Eth Sepolia is the hardest — if Alchemy + QuickNode both reject you, fall back to the PoW faucet (`pk910.de`) and let it run for ~30min.

Verify each balance with `cast` before moving on:

```bash
set -a; source .env.chains; source .env; set +a
DEPLOYER=$(cast wallet address --private-key $PRIVATE_KEY)

echo "Deployer: $DEPLOYER"
echo "Arb Sepolia:  $(cast balance --rpc-url $ARB_SEPOLIA_RPC_URL_HTTP $DEPLOYER) wei"
echo "Base Sepolia: $(cast balance --rpc-url $BASE_SEPOLIA_RPC_URL_HTTP $DEPLOYER) wei"
echo "Eth Sepolia:  $(cast balance --rpc-url $ETH_SEPOLIA_RPC_URL_HTTP $DEPLOYER) wei"
echo "BNB Testnet:  $(cast balance --rpc-url $BNB_TESTNET_RPC_URL_HTTP $DEPLOYER) wei"
echo "Polygon Amoy: $(cast balance --rpc-url $POLYGON_AMOY_RPC_URL_HTTP $DEPLOYER) wei"
```

Each value should be > 0 and roughly match the recommended balance (1 ETH = 1e18 wei; 0.5 ETH = 5e17 wei).

### 0.6 — Connectivity sanity check

Confirm each RPC actually responds.

```bash
set -a; source .env.chains; set +a
for VAR in ARB_SEPOLIA_RPC_URL_HTTP BASE_SEPOLIA_RPC_URL_HTTP ETH_SEPOLIA_RPC_URL_HTTP BNB_TESTNET_RPC_URL_HTTP POLYGON_AMOY_RPC_URL_HTTP; do
  URL="${!VAR}"
  BLOCK=$(cast block-number --rpc-url "$URL" 2>/dev/null || echo "FAIL")
  echo "$VAR  →  block=$BLOCK"
done
```

All 5 should print a recent block number. Any `FAIL` means the URL is wrong or the provider is rate-limiting — fix before Phase 1.

### 0.7 — Phase 0 done check

You're ready for Phase 1 when **all** of these are true:

- [ ] `.gitignore` line 12 widened to `.env*` and `git check-ignore .env.chains` confirms it's ignored
- [ ] Fresh `cast wallet` key generated, address copied to password manager, key copied to password manager + into `smart-contract-revamp/.env`
- [ ] `smart-contract-revamp/.env` has `PRIVATE_KEY`, `ETHERSCAN_API_KEY`, and the 5 owner-style addresses set to your deployer
- [ ] `smart-contract-revamp/.env.chains` has 10 RPC URL values (HTTP + WS for 5 chains)
- [ ] Wallet funded on all 5 chains (`cast balance` shows ≥ 0.05 ETH each, ≥ 0.5 on Arb Sepolia)
- [ ] All 5 chains reachable via `cast block-number`

Reply "Phase 0 done" in chat (without pasting any secret values) and we move to Phase 1.

---

## Phases A–F — Run the orchestrator

Once Phase 0 is signed off, the entire deploy + wiring chain is one command:

```bash
cd smart-contract-revamp
./bin/run-all-cross-chain.sh
```

This runs phases A → F in order. Each phase creates a marker in `.run-all-cross-chain-state/`, so if a phase fails partway you can fix the issue and rerun the same command — completed phases are skipped automatically.

### Recommended invocation pattern (review-friendly)

Run one phase at a time and inspect output before the next:

```bash
./bin/run-all-cross-chain.sh --phase=A   # hub deploy (~30–45 min, ~0.4 ETH)
# Verify: cat deployments/deploy-arb-sepolia-latest.json
# Spot-check on https://sepolia.arbiscan.io/

./bin/run-all-cross-chain.sh --phase=B   # 4 spoke deploys + mock USDC each (~30 min, ~0.04 ETH per spoke)
# Verify: ls deployments/deploy-spoke-*.json

./bin/run-all-cross-chain.sh --phase=C   # spoke-side wiring (~10 min)
# Verify: each spoke gateway/payout has correct peer at hubEid

./bin/run-all-cross-chain.sh --phase=D   # hub-side wiring (~5 min)
# Verify: HubIntentSettler.trustedRemotes(40245) returns base spoke gateway, etc.

./bin/run-all-cross-chain.sh --phase=E   # write unified summary (no chain ops)
./bin/run-all-cross-chain.sh --phase=F   # populate indexer-v3/.env (no chain ops, backs up old .env)
```

Or just run them all unattended:

```bash
./bin/run-all-cross-chain.sh             # A → F end to end
```

### Useful flags

- `--dry-run` — print every command that would run, no transactions sent. Use first to sanity-check.
- `--reset` — wipe `.run-all-cross-chain-state/` so all phases re-run.
- `--skip-indexer-env` — skip Phase F (don't touch `indexer-v3/.env`).
- `--verify` — pass `--verify` through to forge for Etherscan verification (requires `ETHERSCAN_API_KEY`).

### What each phase actually deploys / configures

- **Phase A** — `bin/run-all.sh` (existing, unchanged): deploys 12 hub contracts in 18 steps. Result: `deployments/deploy-arb-sepolia-latest.json`.
- **Phase B** — for each of BASE / ETH / BNB / POLYGON: runs `bin/deploy-spoke.sh` (3 spoke contracts: SpokeVaultStable + SpokePayout + SpokeDepositGateway) then `DeployMockTokens.s.sol` (so we have a USDC ERC20 to deposit). Captures USDC mock address per spoke.
- **Phase C** — for each spoke: runs `script/ConfigureSpokeForM5.s.sol` (new). Sets the spoke gateway peer at `hubEid → HubIntentSettler`, the spoke payout peer at `hubEid → WithdrawalRegistry`, registers the spoke's mock USDC as `BRIDGED` on both the vault and the gateway.
- **Phase D** — runs `script/ConfigureHubForM5.s.sol` (existing, never previously called). Sets the hub-side LZ endpoint, trusted remotes for all 4 spoke gateways, payout endpoint, payout peers for all 4 spoke payouts, and `WithdrawalRegistry.setHubIntentSettler`.
- **Phase E** — writes `deployments/deploy-cross-chain-latest.json` aggregating hub + 4 spoke addresses + LZ EIDs into one file the rest of the system can consume.
- **Phase F** — generates `indexer-v3/.env` from the unified summary + RPC URLs in `.env.chains`. Backs up any existing `.env` to `.env.bak.<timestamp>` first.

## Phase G — Live burn-in trigger + verify ✅ DONE 2026-05-06

After Phase F: start the indexer, trigger a real spoke deposit, watch the `cross_chain_deposit` row transition `INITIATED → CREDITED` once LayerZero confirms (~30s–2min on testnets). Then trigger a `Settlement.settleMatches()` on the hub to validate the Centuari positions processor.

**Outcome:** end-to-end LZ V2 spoke→hub round-trip verified live on testnet (Base Sepolia → Arb Sepolia). 5 contract bugs surfaced + patched. All 3 critical processors (`spoke-deposit-gateway`, `hub-intent-settler`, `balance-ledger`) captured against real events. Detailed evidence (tx hashes, block numbers, indexer row states) + the 5 contract patches are documented in [m8-burn-in-completion.md](m8-burn-in-completion.md).
