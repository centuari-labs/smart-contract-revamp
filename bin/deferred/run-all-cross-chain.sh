#!/usr/bin/env bash
#
# Master cross-chain Phase 1 deployment orchestrator.
#
# Wraps the existing single-chain run-all.sh + deploy-spoke.sh and adds the
# missing LZ wiring + cross-chain summary + indexer-v3 env generation.
#
# Phases:
#   A — Hub stack to Arbitrum Sepolia (calls ./bin/run-all.sh)
#   B — Spoke deploys × 4 (calls ./bin/deploy-spoke.sh per spoke + DeployMockTokens for burn-in USDC)
#   C — Spoke-side LZ wiring + asset classification × 4 (ConfigureSpokeForM5)
#   D — Hub-side LZ wiring (ConfigureHubForM5)
#   E — Unified deploy-cross-chain-latest.json
#   F — indexer-v3/.env auto-population
#
# Phase markers live in .run-all-cross-chain-state/ so the orchestrator is
# resumable: rerun without --reset to skip phases that already completed.
#
# Usage:
#   ./bin/run-all-cross-chain.sh                       # run all phases
#   ./bin/run-all-cross-chain.sh --phase=A             # only Phase A
#   ./bin/run-all-cross-chain.sh --phase=B,C,D         # spokes + both wirings
#   ./bin/run-all-cross-chain.sh --reset               # clear markers, start over
#   ./bin/run-all-cross-chain.sh --skip-indexer-env    # skip Phase F
#   ./bin/run-all-cross-chain.sh --dry-run             # print plan, don't run
#
# Required env (loaded automatically from .env + .env.chains in this directory):
#   PRIVATE_KEY                  — deployer (becomes owner + proxy admin)
#   BACKEND_OPERATOR             — required by run-all.sh
#   SETTLEMENT_OPERATOR          — required by run-all.sh
#   ARB_SEPOLIA_RPC_URL_HTTP     — hub RPC
#   BASE_SEPOLIA_RPC_URL_HTTP    — spoke RPCs
#   ETH_SEPOLIA_RPC_URL_HTTP
#   BNB_TESTNET_RPC_URL_HTTP
#   POLYGON_AMOY_RPC_URL_HTTP
#   ETHERSCAN_API_KEY            — optional, enables --verify
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# This script lives in bin/deferred/, so the repo root is two levels up.
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT_DIR"

STATE_DIR="$ROOT_DIR/.run-all-cross-chain-state"
DEPLOY_DIR="$ROOT_DIR/deployments"
mkdir -p "$STATE_DIR" "$DEPLOY_DIR"

# ---------- arg parsing ----------------------------------------------------
PHASES_REQUESTED=""
RESET=false
SKIP_INDEXER_ENV=false
DRY_RUN=false
VERIFY=${VERIFY:-false}

for arg in "$@"; do
  case "$arg" in
    --phase=*) PHASES_REQUESTED="${arg#--phase=}" ;;
    --reset) RESET=true ;;
    --skip-indexer-env) SKIP_INDEXER_ENV=true ;;
    --dry-run) DRY_RUN=true ;;
    --verify) VERIFY=true ;;
    -h|--help)
      sed -n '2,40p' "$0"
      exit 0
      ;;
    *) echo "Unknown flag: $arg"; exit 1 ;;
  esac
done

if [[ "$RESET" == true ]]; then
  echo "==> Removing all phase markers in $STATE_DIR"
  rm -rf "$STATE_DIR"/*
fi

ALL_PHASES="A B C D E F"
if [[ -z "$PHASES_REQUESTED" ]]; then
  PHASES_TO_RUN="$ALL_PHASES"
else
  PHASES_TO_RUN=$(echo "$PHASES_REQUESTED" | tr ',' ' ')
fi
[[ "$SKIP_INDEXER_ENV" == true ]] && PHASES_TO_RUN=$(echo "$PHASES_TO_RUN" | tr ' ' '\n' | grep -v '^F$' | tr '\n' ' ')

# ---------- env loading ----------------------------------------------------
[[ -f "$ROOT_DIR/.env" ]] || { echo "Missing $ROOT_DIR/.env — populate it first."; exit 1; }
[[ -f "$ROOT_DIR/.env.chains" ]] || { echo "Missing $ROOT_DIR/.env.chains — populate it from the runbook."; exit 1; }

set -a
# shellcheck source=/dev/null
source "$ROOT_DIR/.env"
# shellcheck source=/dev/null
source "$ROOT_DIR/.env.chains"
set +a

# shellcheck source=/dev/null
source "$SCRIPT_DIR/lz-testnet-config.sh"

# ---------- prereq validation ---------------------------------------------
require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing env var: $name"
    exit 1
  fi
}
require_var PRIVATE_KEY
require_var BACKEND_OPERATOR
require_var SETTLEMENT_OPERATOR
require_var ARB_SEPOLIA_RPC_URL_HTTP
require_var BASE_SEPOLIA_RPC_URL_HTTP
require_var ETH_SEPOLIA_RPC_URL_HTTP
require_var BNB_TESTNET_RPC_URL_HTTP
require_var POLYGON_AMOY_RPC_URL_HTTP

DEPLOYER_ADDRESS="$(cast wallet address "$PRIVATE_KEY")"
echo "==> Deployer address: $DEPLOYER_ADDRESS"

# ---------- helpers --------------------------------------------------------
phase_done() { [[ -f "$STATE_DIR/phase-$1-done" ]]; }
mark_phase_done() {
  # Don't create persistent state during dry-run, otherwise the next real
  # run would skip the phase that hasn't actually deployed anything.
  if [[ "$DRY_RUN" == true ]]; then
    echo "[dry-run] would mark phase $1 done"
    return
  fi
  touch "$STATE_DIR/phase-$1-done"
}
should_run_phase() {
  local p="$1"
  [[ " $PHASES_TO_RUN " == *" $p "* ]] || return 1
  if phase_done "$p"; then
    echo "==> Phase $p already done — skipping (use --reset to redo)"
    return 1
  fi
  return 0
}

run_or_echo() {
  if [[ "$DRY_RUN" == true ]]; then
    # Redact private-key value from dry-run echo so it never appears in logs.
    local args=() prev=""
    for a in "$@"; do
      if [[ "$prev" == "--private-key" ]]; then args+=("0x<redacted>"); else args+=("$a"); fi
      prev="$a"
    done
    echo "[dry-run] ${args[*]}"
  else
    "$@"
  fi
}

# Read a JSON field via python (avoids jq dependency)
json_field() {
  local file="$1" field="$2"
  python3 -c "import json,sys; print(json.load(open('$file')).get('$field',''))"
}

# Spoke matrix — order matters for output stability
SPOKE_NAMES=(BASE ETH BNB POLYGON)
spoke_chain_id() {
  case "$1" in
    BASE)    echo 84532 ;;
    ETH)     echo 11155111 ;;
    BNB)     echo 97 ;;
    POLYGON) echo 80002 ;;
  esac
}
spoke_rpc_http() {
  case "$1" in
    BASE)    echo "$BASE_SEPOLIA_RPC_URL_HTTP" ;;
    ETH)     echo "$ETH_SEPOLIA_RPC_URL_HTTP" ;;
    BNB)     echo "$BNB_TESTNET_RPC_URL_HTTP" ;;
    POLYGON) echo "$POLYGON_AMOY_RPC_URL_HTTP" ;;
  esac
}
spoke_rpc_ws() {
  case "$1" in
    BASE)    echo "$BASE_SEPOLIA_RPC_URL_WS" ;;
    ETH)     echo "$ETH_SEPOLIA_RPC_URL_WS" ;;
    BNB)     echo "$BNB_TESTNET_RPC_URL_WS" ;;
    POLYGON) echo "$POLYGON_AMOY_RPC_URL_WS" ;;
  esac
}
spoke_eid() {
  case "$1" in
    BASE)    echo "$LZ_EID_BASE_SEPOLIA" ;;
    ETH)     echo "$LZ_EID_ETH_SEPOLIA" ;;
    BNB)     echo "$LZ_EID_BNB_TESTNET" ;;
    POLYGON) echo "$LZ_EID_POLYGON_AMOY" ;;
  esac
}

# ---------- Phase A: hub deploy -------------------------------------------
phase_a() {
  if ! should_run_phase A; then return 0; fi
  echo "============================================================"
  echo "PHASE A — Hub stack to Arbitrum Sepolia"
  echo "============================================================"

  # run-all.sh writes deploy-<network>-latest.json. Force NETWORK_NAME for clarity.
  export RPC_URL="$ARB_SEPOLIA_RPC_URL_HTTP"
  export NETWORK_NAME="arb-sepolia"

  local FORGE_FLAGS="--broadcast"
  [[ "$VERIFY" == "true" ]] && FORGE_FLAGS="$FORGE_FLAGS --verify"

  run_or_echo bash "$ROOT_DIR/bin/run-all.sh" $FORGE_FLAGS

  local HUB_FILE="$DEPLOY_DIR/deploy-${NETWORK_NAME}-latest.json"
  if [[ "$DRY_RUN" != "true" && ! -f "$HUB_FILE" ]]; then
    echo "FATAL: hub deploy completed but $HUB_FILE missing"
    exit 1
  fi
  echo "==> Hub addresses written to $HUB_FILE"
  mark_phase_done A
}

# ---------- Phase B: spoke deploys × 4 ------------------------------------
phase_b() {
  if ! should_run_phase B; then return 0; fi
  echo "============================================================"
  echo "PHASE B — Spoke deploys × 4 (+ mock USDC per spoke)"
  echo "============================================================"

  for spoke in "${SPOKE_NAMES[@]}"; do
    local CHAIN_ID="$(spoke_chain_id "$spoke")"
    local RPC="$(spoke_rpc_http "$spoke")"
    local EID="$(spoke_eid "$spoke")"
    local STATE_FILE="$STATE_DIR/phase-B-spoke-${spoke}-done"

    if [[ -f "$STATE_FILE" ]]; then
      echo "==> Phase B.$spoke already done — skipping"
      continue
    fi

    echo "------------------------------------------------------------"
    echo "Phase B.$spoke (chain $CHAIN_ID, EID $EID)"
    echo "------------------------------------------------------------"

    # B.1 — spoke contracts (existing script). Idempotency: skip if the
    # per-chain summary file already exists, which means a prior run completed
    # the deploy-spoke step even if the mock-token step (B.2) failed and
    # blocked the per-spoke "done" marker.
    local SPOKE_SUMMARY="$DEPLOY_DIR/deploy-spoke-${CHAIN_ID}-latest.json"
    if [[ -f "$SPOKE_SUMMARY" ]]; then
      echo "==> deploy-spoke-${CHAIN_ID}-latest.json exists — skipping deploy-spoke.sh"
    else
      CHAIN_ID="$CHAIN_ID" \
      SPOKE_RPC_URL="$RPC" \
      PRIVATE_KEY="$PRIVATE_KEY" \
      OWNER="$DEPLOYER_ADDRESS" \
      LZ_ENDPOINT="$LZ_ENDPOINT_V2_ADDRESS" \
      HUB_EID="$LZ_EID_ARB_SEPOLIA" \
      PROXY_ADMIN_OWNER="$DEPLOYER_ADDRESS" \
      VERIFY="$VERIFY" \
        run_or_echo bash "$SCRIPT_DIR/deploy-spoke.sh"
    fi

    # B.2 — mock USDC (and other tokens) for burn-in.
    # --skip-simulation: forge's local CREATE-collision check considers any
    # address with nonzero balance "non-empty" and rejects deploy. EIP-684's
    # actual rule only blocks on nonzero nonce or code, so broadcast succeeds
    # even when simulation fails. Skip simulation to bypass the false positive.
    # Idempotent: if the log file already has a parseable USDC line, reuse
    # that address instead of redeploying 11 fresh tokens.
    local MOCK_OUT_FILE="$STATE_DIR/spoke-${spoke}-mock-tokens.txt"
    parse_usdc() {
      grep -E '^[[:space:]]*USDC[[:space:]]+0x[a-fA-F0-9]{40}$' "$1" \
        | awk '{print $NF}' | head -1
    }

    local USDC_ADDR=""
    if [[ -f "$MOCK_OUT_FILE" ]]; then
      USDC_ADDR=$(parse_usdc "$MOCK_OUT_FILE")
    fi

    if [[ -n "$USDC_ADDR" ]]; then
      echo "==> $spoke mock USDC already deployed: $USDC_ADDR (skipping redeploy)"
    elif [[ "$DRY_RUN" == "true" ]]; then
      echo "[dry-run] forge script DeployMockTokens.s.sol --rpc-url $RPC --skip-simulation ..."
      touch "$MOCK_OUT_FILE"
    else
      forge script script/DeployMockTokens.s.sol:DeployMockTokens \
        --rpc-url "$RPC" \
        --private-key "$PRIVATE_KEY" \
        --skip-simulation \
        --broadcast 2>&1 | tee "$MOCK_OUT_FILE"
      USDC_ADDR=$(parse_usdc "$MOCK_OUT_FILE")
    fi

    if [[ "$DRY_RUN" != "true" && -z "$USDC_ADDR" ]]; then
      echo "FATAL: could not parse USDC mock address from DeployMockTokens output on $spoke"
      exit 1
    fi
    [[ -z "$USDC_ADDR" ]] && USDC_ADDR="0x0000000000000000000000000000000000000000"
    echo "$USDC_ADDR" > "$STATE_DIR/spoke-${spoke}-usdc.txt"
    echo "==> $spoke mock USDC: $USDC_ADDR"

    if [[ "$DRY_RUN" != true ]]; then touch "$STATE_FILE"; fi
  done

  mark_phase_done B
}

# ---------- Phase C: spoke-side LZ wiring × N -----------------------------
phase_c() {
  if ! should_run_phase C; then return 0; fi
  echo "============================================================"
  echo "PHASE C — Spoke-side LZ wiring + asset classification × N"
  echo "============================================================"

  local HUB_FILE="$DEPLOY_DIR/deploy-arb-sepolia-latest.json"
  [[ -f "$HUB_FILE" ]] || { echo "Need $HUB_FILE — run Phase A first"; exit 1; }
  local HUB_INTENT_SETTLER WITHDRAWAL_REGISTRY
  HUB_INTENT_SETTLER="$(json_field "$HUB_FILE" hubIntentSettlerAddress)"
  WITHDRAWAL_REGISTRY="$(json_field "$HUB_FILE" withdrawalRegistryAddress)"
  [[ -n "$HUB_INTENT_SETTLER" && -n "$WITHDRAWAL_REGISTRY" ]] || { echo "Hub addresses missing in $HUB_FILE"; exit 1; }

  for spoke in "${SPOKE_NAMES[@]}"; do
    local CHAIN_ID="$(spoke_chain_id "$spoke")"
    local RPC="$(spoke_rpc_http "$spoke")"
    local STATE_FILE="$STATE_DIR/phase-C-spoke-${spoke}-done"

    if [[ -f "$STATE_FILE" ]]; then
      echo "==> Phase C.$spoke already done — skipping"
      continue
    fi

    local SPOKE_FILE="$DEPLOY_DIR/deploy-spoke-${CHAIN_ID}-latest.json"
    if [[ ! -f "$SPOKE_FILE" ]]; then
      echo "==> Phase C.$spoke skipped — no $SPOKE_FILE (Phase B did not deploy this spoke)"
      continue
    fi

    local SPOKE_GATEWAY SPOKE_VAULT SPOKE_PAYOUT
    SPOKE_GATEWAY="$(python3 -c "import json; d=json.load(open('$SPOKE_FILE')); print(d['contracts']['SpokeDepositGateway']['proxy'])")"
    SPOKE_VAULT="$(python3 -c "import json; d=json.load(open('$SPOKE_FILE')); print(d['contracts']['SpokeVaultStable']['proxy'])")"
    SPOKE_PAYOUT="$(python3 -c "import json; d=json.load(open('$SPOKE_FILE')); print(d['contracts']['SpokePayout']['proxy'])")"

    local USDC
    USDC="$(cat "$STATE_DIR/spoke-${spoke}-usdc.txt" 2>/dev/null || echo '')"

    echo "------------------------------------------------------------"
    echo "Phase C.$spoke (chain $CHAIN_ID)"
    echo "  gateway:           $SPOKE_GATEWAY"
    echo "  vault:             $SPOKE_VAULT"
    echo "  payout:            $SPOKE_PAYOUT"
    echo "  hub settler:       $HUB_INTENT_SETTLER"
    echo "  hub registry:      $WITHDRAWAL_REGISTRY"
    echo "  bridged USDC:      $USDC"
    echo "------------------------------------------------------------"

    SPOKE_GATEWAY="$SPOKE_GATEWAY" \
    SPOKE_VAULT="$SPOKE_VAULT" \
    SPOKE_PAYOUT="$SPOKE_PAYOUT" \
    HUB_EID="$LZ_EID_ARB_SEPOLIA" \
    HUB_INTENT_SETTLER="$HUB_INTENT_SETTLER" \
    WITHDRAWAL_REGISTRY="$WITHDRAWAL_REGISTRY" \
    BRIDGED_ASSETS="$USDC" \
      run_or_echo forge script script/deferred/ConfigureSpokeForM5.s.sol:ConfigureSpokeForM5 \
        --rpc-url "$RPC" \
        --private-key "$PRIVATE_KEY" \
        --broadcast

    if [[ "$DRY_RUN" != true ]]; then touch "$STATE_FILE"; fi
  done

  mark_phase_done C
}

# ---------- Phase D: hub-side LZ wiring -----------------------------------
phase_d() {
  if ! should_run_phase D; then return 0; fi
  echo "============================================================"
  echo "PHASE D — Hub-side LZ wiring (ConfigureHubForM5)"
  echo "============================================================"

  local HUB_FILE="$DEPLOY_DIR/deploy-arb-sepolia-latest.json"
  [[ -f "$HUB_FILE" ]] || { echo "Need $HUB_FILE — run Phase A first"; exit 1; }
  local HUB_INTENT_SETTLER WITHDRAWAL_REGISTRY
  HUB_INTENT_SETTLER="$(json_field "$HUB_FILE" hubIntentSettlerAddress)"
  WITHDRAWAL_REGISTRY="$(json_field "$HUB_FILE" withdrawalRegistryAddress)"

  # Build per-spoke env vars expected by ConfigureHubForM5. Skip spokes whose
  # deploy summary is missing; ConfigureHubForM5 already gracefully no-ops on
  # absent SPOKE_GATEWAY_<chain> via try/catch.
  local CONFIG_ENV=()
  local skipped=()
  for spoke in "${SPOKE_NAMES[@]}"; do
    local CHAIN_ID="$(spoke_chain_id "$spoke")"
    local EID="$(spoke_eid "$spoke")"
    local SPOKE_FILE="$DEPLOY_DIR/deploy-spoke-${CHAIN_ID}-latest.json"
    if [[ ! -f "$SPOKE_FILE" ]]; then
      skipped+=("$spoke")
      continue
    fi

    local SPOKE_GATEWAY SPOKE_PAYOUT
    SPOKE_GATEWAY="$(python3 -c "import json; d=json.load(open('$SPOKE_FILE')); print(d['contracts']['SpokeDepositGateway']['proxy'])")"
    SPOKE_PAYOUT="$(python3 -c "import json; d=json.load(open('$SPOKE_FILE')); print(d['contracts']['SpokePayout']['proxy'])")"

    CONFIG_ENV+=("SPOKE_GATEWAY_${spoke}=$SPOKE_GATEWAY")
    CONFIG_ENV+=("SPOKE_PAYOUT_${spoke}=$SPOKE_PAYOUT")
    CONFIG_ENV+=("SPOKE_EID_${spoke}=$EID")
    CONFIG_ENV+=("SPOKE_CHAIN_ID_${spoke}=$CHAIN_ID")
  done

  if (( ${#skipped[@]} > 0 )); then
    echo "==> Phase D will SKIP these spokes (no deploy summary): ${skipped[*]}"
  fi

  echo "==> Per-spoke env for ConfigureHubForM5:"
  printf '    %s\n' "${CONFIG_ENV[@]}"

  # Export per-spoke env vars from CONFIG_ENV so the forge subprocess sees
  # them. (Can't pipe these through `env CMD` because run_or_echo is a bash
  # function, not a binary.)
  for kv in "${CONFIG_ENV[@]}"; do export "$kv"; done
  export HUB_INTENT_SETTLER WITHDRAWAL_REGISTRY
  export LZ_ENDPOINT="$LZ_ENDPOINT_V2_ADDRESS"

  run_or_echo forge script script/deferred/ConfigureHubForM5.s.sol:ConfigureHubForM5 \
    --rpc-url "$ARB_SEPOLIA_RPC_URL_HTTP" \
    --private-key "$PRIVATE_KEY" \
    --broadcast

  mark_phase_done D
}

# ---------- Phase E: unified summary --------------------------------------
phase_e() {
  if ! should_run_phase E; then return 0; fi
  echo "============================================================"
  echo "PHASE E — Unified deploy-cross-chain-latest.json"
  echo "============================================================"

  local OUT="$DEPLOY_DIR/deploy-cross-chain-latest.json"
  python3 - <<PY
import json, os, glob
from datetime import datetime, timezone

deploy_dir = "$DEPLOY_DIR"
state_dir  = "$STATE_DIR"

hub_path = os.path.join(deploy_dir, "deploy-arb-sepolia-latest.json")
hub = json.load(open(hub_path)) if os.path.exists(hub_path) else {}

spokes = {}
for spoke, chain_id in [("BASE", 84532), ("ETH", 11155111), ("BNB", 97), ("POLYGON", 80002)]:
    path = os.path.join(deploy_dir, f"deploy-spoke-{chain_id}-latest.json")
    if not os.path.exists(path):
        continue
    sp = json.load(open(path))
    usdc_path = os.path.join(state_dir, f"spoke-{spoke}-usdc.txt")
    usdc = open(usdc_path).read().strip() if os.path.exists(usdc_path) else None
    spokes[spoke] = {
        "chainId": chain_id,
        "lzEid": {"BASE": 40245, "ETH": 40161, "BNB": 40102, "POLYGON": 40267}[spoke],
        "contracts": sp.get("contracts", {}),
        "config": sp.get("config", {}),
        "burnInUsdc": usdc,
    }

out = {
    "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "lzEndpointV2": "0x6EDCE65403992e310A62460808c4b910D972f10f",
    "hub": {
        "network": "arbitrum-sepolia",
        "chainId": 421614,
        "lzEid": 40231,
        "contracts": {k: hub.get(k) for k in [
            "balanceLedgerAddress", "centuariAddress", "bondTokenFactoryAddress",
            "hubDepositorAddress", "collateralManagerAddress", "riskModuleAddress",
            "settlementProxy", "withdrawalRegistryAddress", "hubIntentSettlerAddress",
            "settlementLedgerAddress", "faucetAddress",
        ]},
        "mockTokens": hub.get("mockTokens", {}),
        "deployer": hub.get("deployer"),
    },
    "spokes": spokes,
}
out_path = "$OUT"
with open(out_path, "w") as f:
    json.dump(out, f, indent=2)
print(f"Wrote {out_path}")
PY

  mark_phase_done E
}

# ---------- Phase F: indexer-v3 .env --------------------------------------
phase_f() {
  if ! should_run_phase F; then return 0; fi
  echo "============================================================"
  echo "PHASE F — indexer-v3/.env auto-population"
  echo "============================================================"

  local INDEXER_DIR="$ROOT_DIR/../indexer-v3"
  local INDEXER_ENV="$INDEXER_DIR/.env"
  local INDEXER_ENV_BAK="$INDEXER_DIR/.env.bak.$(date +%Y%m%d-%H%M%S)"
  [[ -d "$INDEXER_DIR" ]] || { echo "indexer-v3 not found at $INDEXER_DIR"; exit 1; }

  if [[ -f "$INDEXER_ENV" ]]; then
    cp "$INDEXER_ENV" "$INDEXER_ENV_BAK"
    echo "==> Backed up existing $INDEXER_ENV → $INDEXER_ENV_BAK"
  fi

  local SUMMARY="$DEPLOY_DIR/deploy-cross-chain-latest.json"
  [[ -f "$SUMMARY" ]] || { echo "Missing $SUMMARY — run Phase E first"; exit 1; }

  python3 - "$SUMMARY" "$INDEXER_ENV" <<PY
import json, sys, os
summary_path, env_path = sys.argv[1], sys.argv[2]
d = json.load(open(summary_path))
hub = d["hub"]; hc = hub["contracts"]
spokes = d["spokes"]

# RPC URLs come from the parent .env.chains via shell — we read them here from os.environ
def env(name, fallback=""):
    return os.environ.get(name, fallback)

lines = [
    "# ---- Core ----",
    "DATABASE_URL=postgres://centuari:password@localhost:5432/centuari",
    "PORT=42069",
    "LOG_LEVEL=info",
    "NODE_ENV=development",
    "",
    "# ---- Hub: Arbitrum Sepolia ----",
    f"HUB_CHAIN_ID={hub['chainId']}",
    f"HUB_RPC_URL_WS={env('ARB_SEPOLIA_RPC_URL_WS')}",
    f"HUB_RPC_URL_HTTP={env('ARB_SEPOLIA_RPC_URL_HTTP')}",
    "HUB_START_BLOCK=0",
    "HUB_FINALITY_DEPTH=12",
    "",
    "# ---- Hub contracts ----",
    f"BALANCE_LEDGER_ADDRESS={hc.get('balanceLedgerAddress','')}",
    f"CENTUARI_ADDRESS={hc.get('centuariAddress','')}",
    f"HUB_DEPOSITOR_ADDRESS={hc.get('hubDepositorAddress','')}",
    f"HUB_INTENT_SETTLER_ADDRESS={hc.get('hubIntentSettlerAddress','')}",
    f"WITHDRAWAL_REGISTRY_ADDRESS={hc.get('withdrawalRegistryAddress','')}",
    f"SETTLEMENT_LEDGER_ADDRESS={hc.get('settlementLedgerAddress','')}",
    f"COLLATERAL_MANAGER_ADDRESS={hc.get('collateralManagerAddress','')}",
    "",
]

# Always emit the spoke chain config (chain_id + RPC URLs + finality) for
# every chain so indexer-v3 Zod validation passes. Contract addresses are
# omitted for spokes that weren't deployed in Phase B — they're optional in
# the indexer schema, so the chain watcher boots but finds nothing to tail.
# indexer-v3's Zod schema uses "SPOKE_ETHEREUM_*" (full word) while the
# orchestrator + summary use "SPOKE_ETH_*" (matches ConfigureHubForM5's
# BASE/ETH/BNB/POLYGON convention). Map them at emission time.
spoke_meta = {
    # orchestrator-key  (display label,        rpc-env-prefix, chain-id, finality, indexer-var-name)
    "BASE":    ("Base Sepolia",     "BASE_SEPOLIA",   84532,    32, "BASE"),
    "ETH":     ("Ethereum Sepolia", "ETH_SEPOLIA",    11155111, 64, "ETHEREUM"),
    "BNB":     ("BNB Testnet",      "BNB_TESTNET",    97,       32, "BNB"),
    "POLYGON": ("Polygon Amoy",     "POLYGON_AMOY",   80002,    32, "POLYGON"),
}

for key, (label, env_prefix, chain_id, finality, indexer_var) in spoke_meta.items():
    sp = spokes.get(key)
    var_prefix = "SPOKE_" + indexer_var
    lines += [
        f"# ---- Spoke: {label} ----",
        f"{var_prefix}_CHAIN_ID={chain_id}",
        f"{var_prefix}_RPC_URL_WS={env(env_prefix + '_RPC_URL_WS')}",
        f"{var_prefix}_RPC_URL_HTTP={env(env_prefix + '_RPC_URL_HTTP')}",
        f"{var_prefix}_START_BLOCK=0",
        f"{var_prefix}_FINALITY_DEPTH={finality}",
    ]
    if sp:
        contracts = sp.get("contracts", {})
        gateway = contracts.get("SpokeDepositGateway", {}).get("proxy", "")
        vault = contracts.get("SpokeVaultStable", {}).get("proxy", "")
        lines += [
            f"{var_prefix}_DEPOSIT_GATEWAY_ADDRESS={gateway}",
            f"{var_prefix}_VAULT_STABLE_ADDRESS={vault}",
        ]
    else:
        lines += [
            f"# {var_prefix}_DEPOSIT_GATEWAY_ADDRESS=  # not deployed",
            f"# {var_prefix}_VAULT_STABLE_ADDRESS=    # not deployed",
        ]
    lines.append("")

with open(env_path, "w") as f:
    f.write("\n".join(lines).rstrip() + "\n")
print(f"Wrote {env_path}")
PY

  echo "==> indexer-v3/.env populated. Diff against backup:"
  if [[ -f "$INDEXER_ENV_BAK" ]]; then
    diff "$INDEXER_ENV_BAK" "$INDEXER_ENV" || true
  fi

  mark_phase_done F
}

# ---------- run ------------------------------------------------------------
echo "==> Phases to run: $PHASES_TO_RUN"
[[ "$DRY_RUN" == "true" ]] && echo "==> DRY-RUN — no transactions will be sent"

for p in $PHASES_TO_RUN; do
  case "$p" in
    A) phase_a ;;
    B) phase_b ;;
    C) phase_c ;;
    D) phase_d ;;
    E) phase_e ;;
    F) phase_f ;;
    *) echo "Unknown phase: $p"; exit 1 ;;
  esac
done

echo ""
echo "============================================================"
echo "Cross-chain deployment orchestration complete."
echo "Summary: $DEPLOY_DIR/deploy-cross-chain-latest.json"
echo "============================================================"
