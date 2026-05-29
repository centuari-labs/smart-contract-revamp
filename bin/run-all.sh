#!/usr/bin/env bash
#
# Run all Foundry deployment scripts in dependency order.
# Parameters are supplied via environment variables; optional flags are forwarded to forge script.
#
# Usage:
#   ./bin/run-all.sh [FORGE_SCRIPT_FLAGS...]
#   e.g. ./bin/run-all.sh --broadcast              # deploy + verify on Arbiscan (needs ETHERSCAN_API_KEY)
#        ./bin/run-all.sh --broadcast --no-verify  # deploy without explorer verification
#        ./bin/run-all.sh --verify-only            # re-verify an existing deployment (no deploy)
#
# Environment variables:
#   RPC_URL              - RPC URL for the target chain (used by forge script when set)
#   PRIVATE_KEY          - Private key for the deployer (used when set).
#                          The deployer wallet address derived from PRIVATE_KEY is used
#                          as both the settlement owner and ProxyAdmin owner.
#   BACKEND_OPERATOR     - Required. Backend operator address (used as Faucet operator)
#   FAUCET_TOKENS        - Optional. Comma-separated token addresses to wire to Faucet (grant minter + addToken)
#   SETTLEMENT_OPERATOR  - Required to run DeploySettlement. Settlement engine operator
#   CENTUARI_OWNER       - Optional. Centuari owner; defaults to the deployer wallet address
#   CENTUARI_SETTLEMENT_PLACEHOLDER - Optional. Centuari init settlement; defaults to CENTUARI_OWNER
#   FEE_COLLECTOR        - Optional. Fee collector address; defaults to DEPLOYER_ADDRESS
#   CENTUARI_ADDRESS     - Optional. If set, skip DeployCentuari and use this for downstream steps
#   BALANCE_LEDGER_ADDRESS - Optional. If set, skip DeployBalanceLedger and use this
#   HUB_DEPOSITOR_ADDRESS - Optional. If set, skip DeployHubDepositor and use this
#   PROXY_ADMIN          - Required to run UpgradeSettlement. ProxyAdmin contract address
#   SETTLEMENT_PROXY     - Required to run UpgradeSettlement. Settlement proxy address (alias: PROXY)
#   USE_EXISTING_MOCK_TOKENS - Optional. If "true", reuse mock tokens from a prior deployment summary instead of running DeployMockTokens.
#   MOCK_TOKENS_FILE     - Optional. Path to deployment JSON to reuse mockTokens from. Defaults to deployments/deploy-<NETWORK_SLUG>-latest.json when USE_EXISTING_MOCK_TOKENS=true.
#   ETHERSCAN_API_KEY    - Required for verification (Arbiscan / Etherscan v2 unified key). Without it, --verify is skipped.
#   SKIP_VERIFY          - Optional. If "1" (or pass --no-verify), skip all explorer verification.
#
# Deployment order (Configure* steps are folded into their Deploy* scripts):
#   1. DeployMockTokens
#   2. DeployFaucet
#   3. DeployBalanceLedger
#   4. DeployCentuari (with BalanceLedger; self-registers as a BalanceLedger writer)
#   5. DeployBondFactory (wires the factory into Centuari)
#   6. DeployHubDepositor (self-registers as a writer; whitelists supported assets)
#   7. DeployCollateralStack (RiskModuleStub + CollateralManager; self-registers manager)
#   8. DeploySettlement (self-registers as a BalanceLedger writer)
#   9. SetSettlement on Centuari
#   10. UpgradeSettlement (optional)
#   11. SetOperators
#   12. DeployCrossChainHub (WithdrawalRegistry + HubIntentSettler + SettlementLedger;
#       registers M4 writers + authorizes WithdrawalRegistry on HubDepositor)
#
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

# Load environment variables from .env in the project root if present.
# This exports all variables defined there so they are visible to child processes.
if [[ -f ".env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source ".env"
  set +a
fi

# Collect forge script flags (e.g. --broadcast, --slow, etc.); local flags are handled here
FORGE_EXTRA=()
DEPLOY_ONLY=false
BROADCAST=false
VERIFY_ONLY=false
USE_EXISTING_MOCK_TOKENS="${USE_EXISTING_MOCK_TOKENS:-false}"
for arg in "$@"; do
  case "$arg" in
    --deploy-only)
      DEPLOY_ONLY=true
      ;;
    --reuse-mock-tokens)
      USE_EXISTING_MOCK_TOKENS=true
      ;;
    --verify-only)
      VERIFY_ONLY=true
      ;;
    --no-verify)
      SKIP_VERIFY=1
      ;;
    --broadcast)
      BROADCAST=true
      FORGE_EXTRA+=("$arg")
      ;;
    *)
      FORGE_EXTRA+=("$arg")
      ;;
  esac
done

# Required operators (not needed for --verify-only, which re-verifies an existing deployment)
if [[ "$VERIFY_ONLY" != true && -z "${BACKEND_OPERATOR:-}" ]]; then
  echo "BACKEND_OPERATOR must be set for Faucet deployment"
  exit 1
fi


# Base forge script command fragment (rpc and key when set)
FORGE_BASE=(forge script)
[[ -n "${RPC_URL:-}" ]] && FORGE_BASE+=(--rpc-url "$RPC_URL")
[[ -n "${PRIVATE_KEY:-}" ]] && FORGE_BASE+=(--private-key "$PRIVATE_KEY")

# Detect local RPCs (anvil/hardhat) — explorer verification is meaningless without a public explorer.
is_local_rpc() {
  case "$1" in
    *localhost*|*127.0.0.1*|*0.0.0.0*) return 0 ;;
    *) return 1 ;;
  esac
}

# Always verify on real-network broadcasts (Arbiscan via ETHERSCAN_API_KEY). Opt out with
# SKIP_VERIFY=1 / --no-verify. Appending --verify here makes every forge-script broadcast verify
# inline; the post-deploy verify_deployment() pass re-verifies anything not yet indexed.
if [[ "$BROADCAST" == true && "${SKIP_VERIFY:-0}" != "1" ]] && ! is_local_rpc "${RPC_URL:-}"; then
  if [[ -n "${ETHERSCAN_API_KEY:-}" ]]; then
    FORGE_EXTRA+=(--verify --etherscan-api-key "$ETHERSCAN_API_KEY")
    echo "Contract verification: ENABLED (inline --verify on every broadcast + post-deploy re-verify)"
  else
    echo "Contract verification: SKIPPED (ETHERSCAN_API_KEY unset). Set it, or pass --no-verify to silence."
  fi
fi

# Derive deployer address from PRIVATE_KEY (used as both settlement owner and ProxyAdmin owner)
DEPLOYER_ADDRESS=""
if [[ -n "${PRIVATE_KEY:-}" ]]; then
  if command -v cast >/dev/null 2>&1; then
    DEPLOYER_ADDRESS="$(cast wallet address "$PRIVATE_KEY")"
    export DEPLOYER_ADDRESS
  else
    echo "Warning: 'cast' not found; cannot derive DEPLOYER_ADDRESS from PRIVATE_KEY"
  fi
fi

# Defaults for Centuari deploy
[[ -z "${CENTUARI_OWNER:-}" && -n "${DEPLOYER_ADDRESS:-}" ]] && export CENTUARI_OWNER="$DEPLOYER_ADDRESS"
[[ -z "${CENTUARI_SETTLEMENT_PLACEHOLDER:-}" && -n "${CENTUARI_OWNER:-}" ]] && export CENTUARI_SETTLEMENT_PLACEHOLDER="$CENTUARI_OWNER"
[[ -z "${FEE_COLLECTOR:-}" && -n "${DEPLOYER_ADDRESS:-}" ]] && export FEE_COLLECTOR="$DEPLOYER_ADDRESS"

# Determine chain id and network slug early so they can be reused for file naming and summaries.
CHAIN_ID=""
if command -v cast >/dev/null 2>&1 && [[ -n "${RPC_URL:-}" ]]; then
  CHAIN_ID="$(cast chain-id "$RPC_URL" 2>/dev/null || true)"
fi

NETWORK_NAME="${NETWORK_NAME:-unknown}"
NETWORK_SLUG="$NETWORK_NAME"
if [[ -z "$NETWORK_SLUG" || "$NETWORK_SLUG" == "unknown" ]]; then
  if [[ -n "$CHAIN_ID" ]]; then
    NETWORK_SLUG="chain-$CHAIN_ID"
  else
    NETWORK_SLUG="unknown"
  fi
fi

# Prepare deployments directory and summary file paths up front so they can be reused.
DEPLOYMENTS_DIR="$ROOT_DIR/deployments"
mkdir -p "$DEPLOYMENTS_DIR"

TIMESTAMP_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
FILE_TIMESTAMP="$(date +"%Y%m%d-%H%M%S")"

SUMMARY_FILE="$DEPLOYMENTS_DIR/deploy-${NETWORK_SLUG}-${FILE_TIMESTAMP}.json"
LATEST_FILE="$DEPLOYMENTS_DIR/deploy-${NETWORK_SLUG}-latest.json"

# Resolve default deployment file to reuse mock tokens from when requested.
if [[ "$USE_EXISTING_MOCK_TOKENS" == "true" ]]; then
  if [[ -z "${MOCK_TOKENS_FILE:-}" ]]; then
    MOCK_TOKENS_FILE="$ROOT_DIR/deployments/deploy-${NETWORK_SLUG}-latest.json"
  fi
fi

run_script() {
  "${FORGE_BASE[@]}" "$@" "${FORGE_EXTRA[@]}"
}

# --- Output parsers ---

parse_balance_ledger_proxy() {
  grep -oE 'BalanceLedger proxy: 0x[a-fA-F0-9]{40}' | head -1 | sed 's/BalanceLedger proxy: //'
}
parse_balance_ledger_proxy_admin() {
  grep -oE 'ProxyAdmin: 0x[a-fA-F0-9]{40}' | head -1 | sed 's/ProxyAdmin: //'
}
parse_balance_ledger_impl() {
  grep -oE 'BalanceLedger implementation: 0x[a-fA-F0-9]{40}' | head -1 | sed 's/BalanceLedger implementation: //'
}
parse_centuari_proxy() {
  grep -oE 'Centuari proxy: 0x[a-fA-F0-9]{40}' | head -1 | sed 's/Centuari proxy: //'
}
parse_centuari_proxy_admin() {
  grep -oE 'ProxyAdmin: 0x[a-fA-F0-9]{40}' | head -1 | sed 's/ProxyAdmin: //'
}
parse_bond_factory() {
  grep -oE 'BondFactory: 0x[a-fA-F0-9]{40}' | head -1 | sed 's/BondFactory: //'
}
parse_hub_depositor_proxy() {
  grep -oE 'HubDepositor proxy: 0x[a-fA-F0-9]{40}' | head -1 | sed 's/HubDepositor proxy: //'
}
parse_hub_depositor_proxy_admin() {
  grep -oE 'ProxyAdmin: 0x[a-fA-F0-9]{40}' | head -1 | sed 's/ProxyAdmin: //'
}
parse_hub_depositor_impl() {
  grep -oE 'HubDepositor implementation: 0x[a-fA-F0-9]{40}' | head -1 | sed 's/HubDepositor implementation: //'
}
parse_collateral_manager_proxy() {
  grep -oE 'CollateralManager Proxy: 0x[a-fA-F0-9]{40}' | head -1 | sed 's/CollateralManager Proxy: //'
}
parse_risk_module_stub() {
  grep -oE 'RiskModuleStub: 0x[a-fA-F0-9]{40}' | head -1 | sed 's/RiskModuleStub: //'
}
parse_faucet() {
  grep -oE 'Faucet 0x[a-fA-F0-9]{40}' | head -1 | awk '{print $2}'
}
parse_settlement_proxy() {
  grep -oE 'Proxy: 0x[a-fA-F0-9]{40}' | head -1 | sed 's/Proxy: //'
}
parse_settlement_proxy_admin() {
  grep -oE 'ProxyAdmin: 0x[a-fA-F0-9]{40}' | head -1 | sed 's/ProxyAdmin: //'
}
parse_settlement_impl() {
  grep -oE 'Implementation: 0x[a-fA-F0-9]{40}' | head -1 | sed 's/Implementation: //'
}
parse_upgrade_new_impl() {
  grep -oE 'New Implementation: 0x[a-fA-F0-9]{40}' | head -1 | sed 's/New Implementation: //'
}
parse_withdrawal_registry_proxy() {
  grep -oE 'WithdrawalRegistry proxy: 0x[a-fA-F0-9]{40}' | head -1 | sed 's/WithdrawalRegistry proxy: //'
}
parse_hub_intent_settler_proxy() {
  grep -oE 'HubIntentSettler proxy: 0x[a-fA-F0-9]{40}' | head -1 | sed 's/HubIntentSettler proxy: //'
}
parse_settlement_ledger_proxy() {
  grep -oE 'SettlementLedger proxy: 0x[a-fA-F0-9]{40}' | head -1 | sed 's/SettlementLedger proxy: //'
}
parse_collateral_manager_proxy_admin() {
  grep -oE 'CollateralManager ProxyAdmin: 0x[a-fA-F0-9]{40}' | head -1 | sed 's/CollateralManager ProxyAdmin: //'
}
parse_withdrawal_registry_proxy_admin() {
  grep -oE 'WithdrawalRegistry ProxyAdmin: 0x[a-fA-F0-9]{40}' | head -1 | sed 's/WithdrawalRegistry ProxyAdmin: //'
}
parse_hub_intent_settler_proxy_admin() {
  grep -oE 'HubIntentSettler ProxyAdmin: 0x[a-fA-F0-9]{40}' | head -1 | sed 's/HubIntentSettler ProxyAdmin: //'
}
parse_settlement_ledger_proxy_admin() {
  grep -oE 'SettlementLedger ProxyAdmin: 0x[a-fA-F0-9]{40}' | head -1 | sed 's/SettlementLedger ProxyAdmin: //'
}

write_deploy_summary() {
  : "${MOCK_TOKENS_JSON:={}}"
  : "${FAUCET_ADDRESS:=}"
  : "${BALANCE_LEDGER_ADDRESS:=}"
  : "${BALANCE_LEDGER_PROXY_ADMIN_ADDRESS:=}"
  : "${BALANCE_LEDGER_IMPLEMENTATION_ADDRESS:=}"
  : "${CENTUARI_PROXY_ADMIN_ADDRESS:=}"
  : "${BOND_FACTORY_ADDRESS:=}"
  : "${HUB_DEPOSITOR_ADDRESS:=}"
  : "${HUB_DEPOSITOR_PROXY_ADMIN_ADDRESS:=}"
  : "${HUB_DEPOSITOR_IMPLEMENTATION_ADDRESS:=}"
  : "${COLLATERAL_MANAGER_ADDRESS:=}"
  : "${COLLATERAL_MANAGER_PROXY_ADMIN_ADDRESS:=}"
  : "${RISK_MODULE_STUB_ADDRESS:=}"
  : "${SETTLEMENT_PROXY_ADDRESS:=}"
  : "${SETTLEMENT_PROXY_ADMIN_ADDRESS:=}"
  : "${SETTLEMENT_IMPLEMENTATION_ADDRESS:=}"
  : "${UPGRADED_SETTLEMENT_IMPLEMENTATION_ADDRESS:=}"
  : "${WITHDRAWAL_REGISTRY_ADDRESS:=}"
  : "${WITHDRAWAL_REGISTRY_PROXY_ADMIN_ADDRESS:=}"
  : "${HUB_INTENT_SETTLER_ADDRESS:=}"
  : "${HUB_INTENT_SETTLER_PROXY_ADMIN_ADDRESS:=}"
  : "${SETTLEMENT_LEDGER_ADDRESS:=}"
  : "${SETTLEMENT_LEDGER_PROXY_ADMIN_ADDRESS:=}"

  {
    echo "{"
    echo "  \"network\": \"${NETWORK_NAME}\","
    if [[ -n "$CHAIN_ID" ]]; then
      echo "  \"chainId\": ${CHAIN_ID},"
    else
      echo "  \"chainId\": null,"
    fi
    echo "  \"timestamp\": \"${TIMESTAMP_UTC}\","
    echo "  \"rpcUrl\": \"${RPC_URL:-}\","
    echo "  \"deployer\": \"${DEPLOYER_ADDRESS:-}\","
    echo "  \"backendOperator\": \"${BACKEND_OPERATOR:-}\","
    echo "  \"settlementOperator\": \"${SETTLEMENT_OPERATOR:-}\","
    echo "  \"faucetOperator\": \"${FAUCET_OPERATOR:-}\","
    echo "  \"faucetAddress\": \"${FAUCET_ADDRESS}\","
    echo "  \"balanceLedgerAddress\": \"${BALANCE_LEDGER_ADDRESS}\","
    echo "  \"balanceLedgerProxyAdmin\": \"${BALANCE_LEDGER_PROXY_ADMIN_ADDRESS}\","
    echo "  \"balanceLedgerImplementation\": \"${BALANCE_LEDGER_IMPLEMENTATION_ADDRESS}\","
    echo "  \"centuariAddress\": \"${CENTUARI_ADDRESS:-}\","
    echo "  \"centuariProxyAdmin\": \"${CENTUARI_PROXY_ADMIN_ADDRESS:-}\","
    echo "  \"bondTokenFactoryAddress\": \"${BOND_FACTORY_ADDRESS:-}\","
    echo "  \"hubDepositorAddress\": \"${HUB_DEPOSITOR_ADDRESS}\","
    echo "  \"hubDepositorProxyAdmin\": \"${HUB_DEPOSITOR_PROXY_ADMIN_ADDRESS}\","
    echo "  \"hubDepositorImplementation\": \"${HUB_DEPOSITOR_IMPLEMENTATION_ADDRESS}\","
    echo "  \"collateralManagerAddress\": \"${COLLATERAL_MANAGER_ADDRESS}\","
    echo "  \"collateralManagerProxyAdmin\": \"${COLLATERAL_MANAGER_PROXY_ADMIN_ADDRESS}\","
    echo "  \"riskModuleStubAddress\": \"${RISK_MODULE_STUB_ADDRESS}\","
    echo "  \"settlementProxy\": \"${SETTLEMENT_PROXY_ADDRESS:-}\","
    echo "  \"settlementProxyAdmin\": \"${SETTLEMENT_PROXY_ADMIN_ADDRESS:-}\","
    echo "  \"settlementImplementation\": \"${SETTLEMENT_IMPLEMENTATION_ADDRESS:-}\","
    echo "  \"upgradedSettlementImplementation\": \"${UPGRADED_SETTLEMENT_IMPLEMENTATION_ADDRESS:-}\","
    echo "  \"withdrawalRegistryAddress\": \"${WITHDRAWAL_REGISTRY_ADDRESS}\","
    echo "  \"withdrawalRegistryProxyAdmin\": \"${WITHDRAWAL_REGISTRY_PROXY_ADMIN_ADDRESS}\","
    echo "  \"hubIntentSettlerAddress\": \"${HUB_INTENT_SETTLER_ADDRESS}\","
    echo "  \"hubIntentSettlerProxyAdmin\": \"${HUB_INTENT_SETTLER_PROXY_ADMIN_ADDRESS}\","
    echo "  \"settlementLedgerAddress\": \"${SETTLEMENT_LEDGER_ADDRESS}\","
    echo "  \"settlementLedgerProxyAdmin\": \"${SETTLEMENT_LEDGER_PROXY_ADMIN_ADDRESS}\","
    echo "  \"proxyAdminEnv\": \"${PROXY_ADMIN:-}\","
    echo "  \"settlementProxyEnv\": \"${SETTLEMENT_PROXY:-}\","
    echo "  \"proxyEnv\": \"${PROXY:-}\","
    echo "  \"faucetTokensRaw\": \"${FAUCET_TOKENS:-}\","
    echo "  \"mockTokens\": ${MOCK_TOKENS_JSON}"
    echo "}"
  } > "$SUMMARY_FILE"

  cp "$SUMMARY_FILE" "$LATEST_FILE"
}

load_mock_tokens_from_file() {
  if [[ -z "${MOCK_TOKENS_FILE:-}" ]]; then
    echo "USE_EXISTING_MOCK_TOKENS=true but MOCK_TOKENS_FILE is not set and no default could be resolved."
    exit 1
  fi

  if [[ ! -f "$MOCK_TOKENS_FILE" ]]; then
    echo "MOCK_TOKENS_FILE '$MOCK_TOKENS_FILE' does not exist."
    exit 1
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required to parse MOCK_TOKENS_FILE but was not found in PATH."
    exit 1
  fi

  # Parse mockTokens JSON object and derive a comma-separated list of token addresses.
  __mock_tokens_json=""
  __mock_tokens_addrs=""
  while IFS= read -r __line; do
    if [[ -z "$__mock_tokens_json" ]]; then
      __mock_tokens_json="$__line"
    else
      __mock_tokens_addrs="$__line"
      break
    fi
  done < <(python3 - "$MOCK_TOKENS_FILE" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path) as f:
    data = json.load(f)

mock_tokens = data.get("mockTokens") or {}
if not mock_tokens:
    print("mockTokens key missing or empty in deployment file", file=sys.stderr)
    sys.exit(1)

print(json.dumps(mock_tokens))
print(",".join(mock_tokens.values()))
PY
)

  if [[ -z "$__mock_tokens_json" ]]; then
    echo "Failed to parse mockTokens from '$MOCK_TOKENS_FILE'."
    exit 1
  fi

  MOCK_TOKENS_JSON="$__mock_tokens_json"

  # Only override FAUCET_TOKENS from file if it is not already set.
  if [[ -z "${FAUCET_TOKENS:-}" && -n "$__mock_tokens_addrs" ]]; then
    export FAUCET_TOKENS="$__mock_tokens_addrs"
  fi
}

build_mock_tokens_json() {
  awk '
/0x[0-9a-fA-F]{40}/ {
  addr = ""
  sym = ""
  for (i = 1; i <= NF; i++) {
    if ($i ~ /^0x[0-9a-fA-F]{40}$/) {
      addr = $i
    }
  }
  sym = $1
  if (addr != "" && sym != "") {
    gsub(/"/, "\\\"", sym)
    if (n++ > 0) {
      printf ","
    }
    printf "\"%s\":\"%s\"", sym, addr
  }
}
'
}

# Re-verify a completed deployment on the block explorer (Arbiscan). Runs both as the
# post-deploy fallback (catches contracts the explorer had not yet indexed during the inline
# --verify pass) and standalone via `--verify-only`. Idempotent + non-fatal: already-verified
# or not-yet-indexed contracts are logged and skipped, never aborting the run.
verify_deployment() {
  if [[ "${SKIP_VERIFY:-0}" == "1" ]]; then echo "verify_deployment: skipped (SKIP_VERIFY=1 / --no-verify)"; return 0; fi
  if is_local_rpc "${RPC_URL:-}"; then echo "verify_deployment: skipped (local RPC, no public explorer)"; return 0; fi
  if [[ -z "${ETHERSCAN_API_KEY:-}" ]]; then echo "verify_deployment: skipped (ETHERSCAN_API_KEY unset)"; return 0; fi
  if [[ -z "${CHAIN_ID:-}" ]]; then echo "verify_deployment: skipped (CHAIN_ID unknown — set RPC_URL)"; return 0; fi
  if ! command -v cast >/dev/null 2>&1; then echo "verify_deployment: skipped (cast not found)"; return 0; fi
  if [[ ! -f "$LATEST_FILE" ]]; then echo "verify_deployment: no deployment file at $LATEST_FILE"; return 0; fi

  echo "Verifying deployment from $LATEST_FILE on chain $CHAIN_ID (Arbiscan)..."
  local impl_slot=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc

  _json_get() {
    python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]) or '')" "$LATEST_FILE" "$1" 2>/dev/null || true
  }
  _verify() { # address  FQN  [extra forge args...]
    local addr="$1" fqn="$2"; shift 2
    if [[ -z "$addr" || "$addr" == "null" ]]; then return 0; fi
    echo "  verify $fqn @ $addr"
    forge verify-contract "$addr" "$fqn" --chain "$CHAIN_ID" --etherscan-api-key "$ETHERSCAN_API_KEY" --watch "$@" \
      || echo "    (skipped — already verified or pending explorer indexing)"
  }
  _verify_impl() { # proxy_addr  FQN  (verifies the implementation behind a proxy; impls take no constructor args)
    local proxy="$1" fqn="$2" raw impl
    if [[ -z "$proxy" || "$proxy" == "null" ]]; then return 0; fi
    raw="$(cast storage "$proxy" "$impl_slot" --rpc-url "$RPC_URL" 2>/dev/null || true)"
    if [[ -z "$raw" || ${#raw} -lt 40 ]]; then echo "  ! could not read implementation slot for $fqn ($proxy)"; return 0; fi
    impl="0x${raw: -40}"
    _verify "$impl" "$fqn"
  }

  # Upgradeable implementations (the logic contracts behind each proxy).
  _verify_impl "$(_json_get balanceLedgerAddress)"      "src/core/balance-ledger/BalanceLedger.sol:BalanceLedger"
  _verify_impl "$(_json_get centuariAddress)"           "src/core/centuari/Centuari.sol:Centuari"
  _verify_impl "$(_json_get hubDepositorAddress)"       "src/core/cross-chain/HubDepositor.sol:HubDepositor"
  _verify_impl "$(_json_get collateralManagerAddress)"  "src/core/collateral/CollateralManager.sol:CollateralManager"
  _verify_impl "$(_json_get settlementProxy)"           "src/core/settlement/Settlement.sol:Settlement"
  _verify_impl "$(_json_get withdrawalRegistryAddress)" "src/core/cross-chain/WithdrawalRegistry.sol:WithdrawalRegistry"
  _verify_impl "$(_json_get hubIntentSettlerAddress)"   "src/core/cross-chain/HubIntentSettler.sol:HubIntentSettler"
  _verify_impl "$(_json_get settlementLedgerAddress)"   "src/core/cross-chain/SettlementLedger.sol:SettlementLedger"

  # Non-upgradeable singletons (constructor args fetched from the on-chain creation tx).
  _verify "$(_json_get riskModuleStubAddress)"   "src/core/risk/RiskModuleStub.sol:RiskModuleStub"                           --guess-constructor-args
  _verify "$(_json_get faucetAddress)"           "src/mocks/Faucet.sol:Faucet"                                               --guess-constructor-args
  _verify "$(_json_get bondTokenFactoryAddress)" "src/core/centuari/CentuariBondERC20Factory.sol:CentuariBondERC20Factory"   --guess-constructor-args

  # Mock testnet tokens (best-effort; also verified inline during DeployMockTokens).
  while IFS= read -r mt; do
    if [[ -n "$mt" ]]; then _verify "$mt" "src/mocks/MockToken.sol:MockToken" --guess-constructor-args; fi
  done < <(python3 -c "import json,sys;[print(v) for v in (json.load(open(sys.argv[1])).get('mockTokens') or {}).values()]" "$LATEST_FILE" 2>/dev/null || true)

  echo "verify_deployment: done"
}

# --verify-only: re-verify an existing deployment and exit, skipping all deploy steps.
if [[ "$VERIFY_ONLY" == true ]]; then
  echo "=== --verify-only: verifying existing deployment ($LATEST_FILE), skipping deploy ==="
  verify_deployment
  echo "=== run-all.sh (--verify-only) finished ==="
  exit 0
fi

TOTAL_STEPS=12

# ===========================
# Step 1: DeployMockTokens
# ===========================
if [[ "$USE_EXISTING_MOCK_TOKENS" == "true" ]]; then
  echo "=== 1/$TOTAL_STEPS DeployMockTokens (reuse existing) ==="
  echo "Using existing mockTokens from $MOCK_TOKENS_FILE (skip DeployMockTokens script)"
  load_mock_tokens_from_file
else
  echo "=== 1/$TOTAL_STEPS DeployMockTokens ==="
  deploy_mock_output=$(run_script script/DeployMockTokens.s.sol:DeployMockTokens 2>&1) || {
    status=$?
    echo "$deploy_mock_output"
    echo "DeployMockTokens failed with status $status"
    exit "$status"
  }
  echo "$deploy_mock_output"

  mock_tokens_kv=""
  mock_tokens_kv=$(echo "$deploy_mock_output" | build_mock_tokens_json || true)
  if [[ -n "$mock_tokens_kv" ]]; then
    MOCK_TOKENS_JSON="{${mock_tokens_kv}}"
  else
    MOCK_TOKENS_JSON="{}"
  fi

  # If FAUCET_TOKENS not preset, derive from DeployMockTokens output (all 0x... addresses, comma-separated)
  if [[ -z "${FAUCET_TOKENS:-}" ]]; then
    mock_token_addrs=$(echo "$deploy_mock_output" | grep -oE '0x[a-fA-F0-9]{40}' | tr '\n' ',' | sed 's/,$//')
    if [[ -n "$mock_token_addrs" ]]; then
      export FAUCET_TOKENS="$mock_token_addrs"
      echo "Auto-set FAUCET_TOKENS from DeployMockTokens: $FAUCET_TOKENS"
    fi
  fi
fi

# ===========================
# Step 2: DeployFaucet
# ===========================
echo "=== 2/$TOTAL_STEPS DeployFaucet ==="
export FAUCET_OPERATOR="$BACKEND_OPERATOR"
deploy_faucet_output=$(run_script script/DeployFaucet.s.sol:DeployFaucet 2>&1) || {
  status=$?
  echo "$deploy_faucet_output"
  echo "DeployFaucet failed with status $status"
  exit "$status"
}
echo "$deploy_faucet_output"
FAUCET_ADDRESS="$(echo "$deploy_faucet_output" | parse_faucet || true)"

# ===========================
# Step 3: DeployBalanceLedger
# ===========================
echo "=== 3/$TOTAL_STEPS DeployBalanceLedger ==="
if [[ -z "${BALANCE_LEDGER_ADDRESS:-}" ]]; then
  if [[ -n "${DEPLOYER_ADDRESS:-}" ]]; then
    out=$(run_script script/DeployBalanceLedger.s.sol:DeployBalanceLedger \
      --sig "run(address,bool,address)" \
      "$DEPLOYER_ADDRESS" true "$DEPLOYER_ADDRESS" 2>&1)
    echo "$out"
    BL_PROXY=$(echo "$out" | parse_balance_ledger_proxy)
    if [[ -n "$BL_PROXY" ]]; then
      export BALANCE_LEDGER_ADDRESS="$BL_PROXY"
      echo "Captured BALANCE_LEDGER_ADDRESS=$BALANCE_LEDGER_ADDRESS"
    fi
    BALANCE_LEDGER_PROXY_ADMIN_ADDRESS="$(echo "$out" | parse_balance_ledger_proxy_admin || true)"
    BALANCE_LEDGER_IMPLEMENTATION_ADDRESS="$(echo "$out" | parse_balance_ledger_impl || true)"
  else
    echo "Skipping DeployBalanceLedger (set PRIVATE_KEY so DEPLOYER_ADDRESS can be derived)"
  fi
else
  echo "Using existing BALANCE_LEDGER_ADDRESS=$BALANCE_LEDGER_ADDRESS (skip deploy)"
fi

# ===========================
# Step 4: DeployCentuari
# ===========================
echo "=== 4/$TOTAL_STEPS DeployCentuari ==="
if [[ -n "${DEPLOYER_ADDRESS:-}" && -n "${BALANCE_LEDGER_ADDRESS:-}" ]]; then
  if [[ -z "${CENTUARI_ADDRESS:-}" ]]; then
    out=$(run_script script/DeployCentuari.s.sol:DeployCentuari \
      --sig "run(address,address,address,address,address)" \
      "$CENTUARI_OWNER" "$CENTUARI_SETTLEMENT_PLACEHOLDER" "$BALANCE_LEDGER_ADDRESS" "$FEE_COLLECTOR" "$DEPLOYER_ADDRESS" 2>&1)
    echo "$out"
    CENTUARI=$(echo "$out" | parse_centuari_proxy)
    if [[ -n "$CENTUARI" ]]; then
      export CENTUARI_ADDRESS="$CENTUARI"
      echo "Captured CENTUARI_ADDRESS=$CENTUARI_ADDRESS"
    fi
    CENTUARI_PROXY_ADMIN_ADDRESS="$(echo "$out" | parse_centuari_proxy_admin || true)"
  else
    echo "Using existing CENTUARI_ADDRESS=$CENTUARI_ADDRESS (skip deploy)"
  fi
else
  echo "Skipping DeployCentuari (ensure PRIVATE_KEY is set so DEPLOYER_ADDRESS can be derived, and BALANCE_LEDGER_ADDRESS is set)"
fi

# ===========================
# Step 5: DeployBondFactory
# ===========================
echo "=== 5/$TOTAL_STEPS DeployBondFactory ==="
if [[ -n "${CENTUARI_ADDRESS:-}" ]]; then
  if [[ -z "${BOND_FACTORY_ADDRESS:-}" ]]; then
    out=$(run_script script/DeployBondFactory.s.sol:DeployBondFactory \
      --sig "run(address)" \
      "$CENTUARI_ADDRESS" 2>&1)
    echo "$out"
    BOND_FACTORY=$(echo "$out" | parse_bond_factory)
    if [[ -n "$BOND_FACTORY" ]]; then
      export BOND_FACTORY_ADDRESS="$BOND_FACTORY"
      echo "Captured BOND_FACTORY_ADDRESS=$BOND_FACTORY_ADDRESS"
    fi
  else
    echo "Using existing BOND_FACTORY_ADDRESS=$BOND_FACTORY_ADDRESS (skip deploy)"
  fi
else
  echo "Skipping DeployBondFactory (set CENTUARI_ADDRESS to run)"
fi

# ===========================
# Step 6: DeployHubDepositor (self-registers as a writer; whitelists supported assets)
# ===========================
echo "=== 6/$TOTAL_STEPS DeployHubDepositor ==="
if [[ -z "${HUB_DEPOSITOR_ADDRESS:-}" ]]; then
  if [[ -n "${DEPLOYER_ADDRESS:-}" && -n "${BALANCE_LEDGER_ADDRESS:-}" ]]; then
    # Build a Solidity address[] literal of supported assets from the comma-separated
    # FAUCET_TOKENS list (all deployed mock token addresses). Empty -> [] (none whitelisted).
    if [[ -n "${FAUCET_TOKENS:-}" ]]; then
      IFS=',' read -ra TOKEN_ARRAY <<< "$FAUCET_TOKENS"
      SOLIDITY_ARRAY="[$(printf '%s,' "${TOKEN_ARRAY[@]}" | sed 's/,$//' )]"
    else
      SOLIDITY_ARRAY="[]"
    fi
    out=$(run_script script/DeployHubDepositor.s.sol:DeployHubDepositor \
      --sig "run(address,address,address,address[])" \
      "$DEPLOYER_ADDRESS" "$BALANCE_LEDGER_ADDRESS" "$DEPLOYER_ADDRESS" "$SOLIDITY_ARRAY" 2>&1)
    echo "$out"
    HD_PROXY=$(echo "$out" | parse_hub_depositor_proxy)
    if [[ -n "$HD_PROXY" ]]; then
      export HUB_DEPOSITOR_ADDRESS="$HD_PROXY"
      echo "Captured HUB_DEPOSITOR_ADDRESS=$HUB_DEPOSITOR_ADDRESS"
    fi
    HUB_DEPOSITOR_PROXY_ADMIN_ADDRESS="$(echo "$out" | parse_hub_depositor_proxy_admin || true)"
    HUB_DEPOSITOR_IMPLEMENTATION_ADDRESS="$(echo "$out" | parse_hub_depositor_impl || true)"
  else
    echo "Skipping DeployHubDepositor (set PRIVATE_KEY and BALANCE_LEDGER_ADDRESS)"
  fi
else
  echo "Using existing HUB_DEPOSITOR_ADDRESS=$HUB_DEPOSITOR_ADDRESS (skip deploy)"
fi

# ===========================
# Step 7: DeployCollateralStack
# ===========================
echo "=== 7/$TOTAL_STEPS DeployCollateralStack ==="
if [[ -z "${COLLATERAL_MANAGER_ADDRESS:-}" ]]; then
  if [[ -n "${DEPLOYER_ADDRESS:-}" && -n "${BALANCE_LEDGER_ADDRESS:-}" && -n "${BACKEND_OPERATOR:-}" ]]; then
    out=$(run_script script/DeployCollateralStack.s.sol:DeployCollateralStack \
      --sig "run(address,address,address,address)" \
      "$DEPLOYER_ADDRESS" "$BACKEND_OPERATOR" "$BALANCE_LEDGER_ADDRESS" "$DEPLOYER_ADDRESS" 2>&1)
    echo "$out"
    CM_PROXY=$(echo "$out" | parse_collateral_manager_proxy)
    if [[ -n "$CM_PROXY" ]]; then
      export COLLATERAL_MANAGER_ADDRESS="$CM_PROXY"
      echo "Captured COLLATERAL_MANAGER_ADDRESS=$COLLATERAL_MANAGER_ADDRESS"
    fi
    RISK_MODULE_STUB_ADDRESS="$(echo "$out" | parse_risk_module_stub || true)"
    COLLATERAL_MANAGER_PROXY_ADMIN_ADDRESS="$(echo "$out" | parse_collateral_manager_proxy_admin || true)"
  else
    echo "Skipping DeployCollateralStack (set PRIVATE_KEY, BALANCE_LEDGER_ADDRESS, and BACKEND_OPERATOR)"
  fi
else
  echo "Using existing COLLATERAL_MANAGER_ADDRESS=$COLLATERAL_MANAGER_ADDRESS (skip deploy)"
fi

# ===========================
# Step 8: DeploySettlement (self-registers as a BalanceLedger writer)
# ===========================
echo "=== 8/$TOTAL_STEPS DeploySettlement ==="
if [[ -n "${DEPLOYER_ADDRESS:-}" && -n "${SETTLEMENT_OPERATOR:-}" && -n "${CENTUARI_ADDRESS:-}" && -n "${BALANCE_LEDGER_ADDRESS:-}" ]]; then
  deploy_settlement_output=$(run_script script/DeploySettlement.s.sol:DeploySettlement \
    --sig "run(address,address,address,address,address)" \
    "$DEPLOYER_ADDRESS" "$SETTLEMENT_OPERATOR" "$CENTUARI_ADDRESS" "$BALANCE_LEDGER_ADDRESS" "$DEPLOYER_ADDRESS" 2>&1) || {
    status=$?
    echo "$deploy_settlement_output"
    echo "DeploySettlement failed with status $status"
    exit "$status"
  }
  echo "$deploy_settlement_output"
  SETTLEMENT_PROXY_ADDRESS="$(echo "$deploy_settlement_output" | parse_settlement_proxy || true)"
  SETTLEMENT_PROXY_ADMIN_ADDRESS="$(echo "$deploy_settlement_output" | parse_settlement_proxy_admin || true)"
  SETTLEMENT_IMPLEMENTATION_ADDRESS="$(echo "$deploy_settlement_output" | parse_settlement_impl || true)"
else
  echo "Skipping DeploySettlement (ensure PRIVATE_KEY is set so DEPLOYER_ADDRESS can be derived, and SETTLEMENT_OPERATOR, CENTUARI_ADDRESS, BALANCE_LEDGER_ADDRESS are set)"
fi

# ===========================
# Step 9: SetSettlement on Centuari
# ===========================
echo "=== 9/$TOTAL_STEPS SetSettlement on Centuari ==="
if [[ -n "${CENTUARI_ADDRESS:-}" && -n "${SETTLEMENT_PROXY_ADDRESS:-}" && -n "${PRIVATE_KEY:-}" && -n "${RPC_URL:-}" ]]; then
  echo "Updating Centuari._settlement to the deployed Settlement proxy..."
  echo "  Centuari:         $CENTUARI_ADDRESS"
  echo "  Settlement Proxy: $SETTLEMENT_PROXY_ADDRESS"
  cast send "$CENTUARI_ADDRESS" "setSettlement(address)" "$SETTLEMENT_PROXY_ADDRESS" \
    --private-key "$PRIVATE_KEY" \
    --rpc-url "$RPC_URL"

  current_settlement="$(cast call "$CENTUARI_ADDRESS" "settlement()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo '<call failed>')"
  echo "  Verified settlement() = $current_settlement"
else
  echo "Skipping SetSettlement on Centuari (need CENTUARI_ADDRESS, SETTLEMENT_PROXY_ADDRESS, PRIVATE_KEY, and RPC_URL)"
fi

# ===========================
# Step 10: UpgradeSettlement (optional)
# ===========================
echo "=== 10/$TOTAL_STEPS UpgradeSettlement ==="
PROXY="${SETTLEMENT_PROXY:-${PROXY:-}}"
if [[ "$DEPLOY_ONLY" == true ]]; then
  echo "Skipping UpgradeSettlement (--deploy-only)"
elif [[ -n "${PROXY_ADMIN:-}" && -n "$PROXY" ]]; then
  upgrade_settlement_output=$(run_script script/UpgradeSettlement.s.sol:UpgradeSettlement \
    --sig "run(address,address)" \
    "$PROXY_ADMIN" "$PROXY" 2>&1) || {
    status=$?
    echo "$upgrade_settlement_output"
    echo "UpgradeSettlement failed with status $status"
    exit "$status"
  }
  echo "$upgrade_settlement_output"
  UPGRADED_SETTLEMENT_IMPLEMENTATION_ADDRESS="$(echo "$upgrade_settlement_output" | parse_upgrade_new_impl || true)"
else
  echo "Skipping UpgradeSettlement (set PROXY_ADMIN and SETTLEMENT_PROXY or PROXY to run)"
fi

# ===========================
# Step 11: SetOperators
# ===========================
echo "=== 11/$TOTAL_STEPS SetOperators ==="
if [[ -n "${CENTUARI_ADDRESS:-}" || -n "${SETTLEMENT_PROXY_ADDRESS:-}" || -n "${FAUCET_ADDRESS:-}" ]]; then
  echo "Writing deployment summary for set_operators.sh"
  write_deploy_summary
  DEPLOY_JSON="$SUMMARY_FILE" "$ROOT_DIR/bin/set_operators.sh"
else
  echo "Skipping set_operators.sh (no contract addresses available)"
fi

# ===========================
# Step 12: DeployCrossChainHub (M4: WithdrawalRegistry + HubIntentSettler + SettlementLedger;
#          also registers M4 writers + authorizes WithdrawalRegistry on HubDepositor)
# ===========================
echo "=== 12/$TOTAL_STEPS DeployCrossChainHub ==="
if [[ -n "${DEPLOYER_ADDRESS:-}" && -n "${BACKEND_OPERATOR:-}" && -n "${BALANCE_LEDGER_ADDRESS:-}" && -n "${RISK_MODULE_STUB_ADDRESS:-}" && -n "${HUB_DEPOSITOR_ADDRESS:-}" ]]; then
  out=$(run_script script/DeployCrossChainHub.s.sol:DeployCrossChainHub \
    --sig "run(address,address,address,address,address,address)" \
    "$DEPLOYER_ADDRESS" "$BACKEND_OPERATOR" "$BALANCE_LEDGER_ADDRESS" "$RISK_MODULE_STUB_ADDRESS" "$HUB_DEPOSITOR_ADDRESS" "$DEPLOYER_ADDRESS" 2>&1) || {
    status=$?
    echo "$out"
    echo "DeployCrossChainHub failed with status $status"
    exit "$status"
  }
  echo "$out"
  WR_PROXY=$(echo "$out" | parse_withdrawal_registry_proxy)
  if [[ -n "$WR_PROXY" ]]; then
    export WITHDRAWAL_REGISTRY_ADDRESS="$WR_PROXY"
    echo "Captured WITHDRAWAL_REGISTRY_ADDRESS=$WITHDRAWAL_REGISTRY_ADDRESS"
  fi
  HIS_PROXY=$(echo "$out" | parse_hub_intent_settler_proxy)
  if [[ -n "$HIS_PROXY" ]]; then
    export HUB_INTENT_SETTLER_ADDRESS="$HIS_PROXY"
    echo "Captured HUB_INTENT_SETTLER_ADDRESS=$HUB_INTENT_SETTLER_ADDRESS"
  fi
  SL_PROXY=$(echo "$out" | parse_settlement_ledger_proxy)
  if [[ -n "$SL_PROXY" ]]; then
    export SETTLEMENT_LEDGER_ADDRESS="$SL_PROXY"
    echo "Captured SETTLEMENT_LEDGER_ADDRESS=$SETTLEMENT_LEDGER_ADDRESS"
  fi
  WITHDRAWAL_REGISTRY_PROXY_ADMIN_ADDRESS="$(echo "$out" | parse_withdrawal_registry_proxy_admin || true)"
  HUB_INTENT_SETTLER_PROXY_ADMIN_ADDRESS="$(echo "$out" | parse_hub_intent_settler_proxy_admin || true)"
  SETTLEMENT_LEDGER_PROXY_ADMIN_ADDRESS="$(echo "$out" | parse_settlement_ledger_proxy_admin || true)"
else
  echo "Skipping DeployCrossChainHub (need DEPLOYER_ADDRESS, BACKEND_OPERATOR, BALANCE_LEDGER_ADDRESS, RISK_MODULE_STUB_ADDRESS, HUB_DEPOSITOR_ADDRESS)"
fi

echo "=== Writing deployment summary ==="
write_deploy_summary

echo "Deployment summary written to $SUMMARY_FILE"
echo "Latest deployment summary symlink at $LATEST_FILE"

# ===========================
# Post-deploy: export ABIs and sync to consumer services.
# Skip with SKIP_SYNC=1 (e.g. for partial / debug runs that shouldn't propagate addresses).
# ===========================
if [[ "${SKIP_SYNC:-0}" != "1" ]]; then
  echo "=== Exporting ABIs (./bin/export-abi.sh) ==="
  "$SCRIPT_DIR/export-abi.sh"

  echo "=== Syncing ABIs + addresses to consumer services (./bin/sync-to-services.sh) ==="
  "$SCRIPT_DIR/sync-to-services.sh" --network="$NETWORK_SLUG"

  echo "=== Verifying services are on the latest deployment (sync-to-services.sh --check) ==="
  "$SCRIPT_DIR/sync-to-services.sh" --network="$NETWORK_SLUG" --check
else
  echo "Skipping export-abi + sync-to-services (SKIP_SYNC=1)"
fi

# ===========================
# Post-deploy: re-verify contracts on the explorer. Fallback that re-attempts verification for
# anything not yet indexed during the inline --verify pass. No-op on local chains, when
# SKIP_VERIFY=1 / --no-verify, or when ETHERSCAN_API_KEY is unset.
# ===========================
verify_deployment

echo "=== run-all.sh finished ==="
