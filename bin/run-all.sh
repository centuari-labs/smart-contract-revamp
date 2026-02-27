#!/usr/bin/env bash
#
# Run all Foundry deployment scripts in dependency order.
# Parameters are supplied via environment variables; optional flags are forwarded to forge script.
#
# Usage:
#   ./bin/run-all.sh [FORGE_SCRIPT_FLAGS...]
#   e.g. ./bin/run-all.sh --broadcast
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
#   TREASURY_ADDRESS     - Optional. If set, skip DeployTreasury and use this for DeployCentuari / setCentuariContract
#   CENTUARI_ADDRESS     - Optional. If set, skip DeployCentuari and use this for setCentuariContract / DeploySettlement
#   PROXY_ADMIN          - Required to run UpgradeSettlement. ProxyAdmin contract address
#   SETTLEMENT_PROXY     - Required to run UpgradeSettlement. Settlement proxy address (alias: PROXY)
#
# Order: DeployMockTokens -> DeployFaucet -> DeployTreasury (capture TREASURY) -> DeployCentuari (capture CENTUARI)
#        -> DeployTreasury(treasury, centuari) [setCentuariContract] -> DeploySettlement -> UpgradeSettlement
# Treasury and Centuari addresses are parsed from script output when not provided via env.
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

# Collect forge script flags (e.g. --broadcast, --slow, etc.); --deploy-only is handled here
FORGE_EXTRA=()
DEPLOY_ONLY=false
for arg in "$@"; do
  if [[ "$arg" == "--deploy-only" ]]; then
    DEPLOY_ONLY=true
  else
    FORGE_EXTRA+=("$arg")
  fi
done

# Required operators
if [[ -z "${BACKEND_OPERATOR:-}" ]]; then
  echo "BACKEND_OPERATOR must be set for Faucet deployment"
  exit 1
fi

# Base forge script command fragment (rpc and key when set)
FORGE_BASE=(forge script)
[[ -n "${RPC_URL:-}" ]] && FORGE_BASE+=(--rpc-url "$RPC_URL")
[[ -n "${PRIVATE_KEY:-}" ]] && FORGE_BASE+=(--private-key "$PRIVATE_KEY")

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

run_script() {
  "${FORGE_BASE[@]}" "$@" "${FORGE_EXTRA[@]}"
}

# Parse Treasury address from forge script output (line "Treasury: 0x...")
parse_treasury() {
  grep -oE 'Treasury: 0x[a-fA-F0-9]{40}' | head -1 | sed 's/Treasury: //'
}
# Parse Centuari proxy from forge script output (line "Centuari proxy: 0x...")
parse_centuari_proxy() {
  grep -oE 'Centuari proxy: 0x[a-fA-F0-9]{40}' | head -1 | sed 's/Centuari proxy: //'
}
parse_centuari_proxy_admin() {
  grep -oE 'ProxyAdmin: 0x[a-fA-F0-9]{40}' | head -1 | sed 's/ProxyAdmin: //'
}
# Parse Faucet address from forge script output (line "Faucet 0x...")
parse_faucet() {
  grep -oE 'Faucet 0x[a-fA-F0-9]{40}' | head -1 | awk '{print $2}'
}
# Parse Settlement deployment information from forge script output
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

echo "=== 1/7 DeployMockTokens ==="
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

echo "=== 2/7 DeployFaucet ==="
export FAUCET_OPERATOR="$BACKEND_OPERATOR"
deploy_faucet_output=$(run_script script/DeployFaucet.s.sol:DeployFaucet 2>&1) || {
  status=$?
  echo "$deploy_faucet_output"
  echo "DeployFaucet failed with status $status"
  exit "$status"
}
echo "$deploy_faucet_output"
FAUCET_ADDRESS="$(echo "$deploy_faucet_output" | parse_faucet || true)"

echo "=== 3/7 DeployTreasury ==="
if [[ -z "${TREASURY_ADDRESS:-}" ]]; then
  out=$(run_script script/DeployTreasury.s.sol:DeployTreasury 2>&1)
  echo "$out"
  TREASURY=$(echo "$out" | parse_treasury)
  if [[ -n "$TREASURY" ]]; then
    export TREASURY_ADDRESS="$TREASURY"
    echo "Captured TREASURY_ADDRESS=$TREASURY_ADDRESS"
  fi
else
  echo "Using existing TREASURY_ADDRESS=$TREASURY_ADDRESS (skip deploy)"
fi

echo "=== 4/7 DeployCentuari ==="
if [[ -n "${DEPLOYER_ADDRESS:-}" && -n "${TREASURY_ADDRESS:-}" ]]; then
  if [[ -z "${CENTUARI_ADDRESS:-}" ]]; then
    out=$(run_script script/DeployCentuari.s.sol:DeployCentuari \
      --sig "run(address,address,address,address)" \
      "$CENTUARI_OWNER" "$CENTUARI_SETTLEMENT_PLACEHOLDER" "$TREASURY_ADDRESS" "$DEPLOYER_ADDRESS" 2>&1)
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
  echo "Skipping DeployCentuari (ensure PRIVATE_KEY is set so DEPLOYER_ADDRESS can be derived, and TREASURY_ADDRESS is set, or set CENTUARI_ADDRESS to use existing)"
fi

echo "=== 5/7 DeployTreasury (setCentuariContract) ==="
if [[ -n "${TREASURY_ADDRESS:-}" && -n "${CENTUARI_ADDRESS:-}" ]]; then
  run_script script/DeployTreasury.s.sol:DeployTreasury \
    --sig "run(address,address)" \
    "$TREASURY_ADDRESS" "$CENTUARI_ADDRESS"
else
  echo "Skipping setCentuariContract (set TREASURY_ADDRESS and CENTUARI_ADDRESS to run)"
fi

echo "=== 6/7 DeploySettlement ==="
if [[ -n "${DEPLOYER_ADDRESS:-}" && -n "${SETTLEMENT_OPERATOR:-}" && -n "${CENTUARI_ADDRESS:-}" ]]; then
  deploy_settlement_output=$(run_script script/DeploySettlement.s.sol:DeploySettlement \
    --sig "run(address,address,address,address)" \
    "$DEPLOYER_ADDRESS" "$SETTLEMENT_OPERATOR" "$CENTUARI_ADDRESS" "$DEPLOYER_ADDRESS" 2>&1) || {
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
  echo "Skipping DeploySettlement (ensure PRIVATE_KEY is set so DEPLOYER_ADDRESS can be derived, and SETTLEMENT_OPERATOR and CENTUARI_ADDRESS are set)"
fi

echo "=== 7/7 UpgradeSettlement ==="
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
echo "=== Writing deployment summary ==="

DEPLOYMENTS_DIR="$ROOT_DIR/deployments"
mkdir -p "$DEPLOYMENTS_DIR"

TIMESTAMP_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
FILE_TIMESTAMP="$(date +"%Y%m%d-%H%M%S")"

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

SUMMARY_FILE="$DEPLOYMENTS_DIR/deploy-${NETWORK_SLUG}-${FILE_TIMESTAMP}.json"
LATEST_FILE="$DEPLOYMENTS_DIR/deploy-${NETWORK_SLUG}-latest.json"

: "${MOCK_TOKENS_JSON:={}}"
: "${FAUCET_ADDRESS:=}"
: "${CENTUARI_PROXY_ADMIN_ADDRESS:=}"
: "${SETTLEMENT_PROXY_ADDRESS:=}"
: "${SETTLEMENT_PROXY_ADMIN_ADDRESS:=}"
: "${SETTLEMENT_IMPLEMENTATION_ADDRESS:=}"
: "${UPGRADED_SETTLEMENT_IMPLEMENTATION_ADDRESS:=}"

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
  echo "  \"treasuryAddress\": \"${TREASURY_ADDRESS:-}\","
  echo "  \"centuariAddress\": \"${CENTUARI_ADDRESS:-}\","
  echo "  \"centuariProxyAdmin\": \"${CENTUARI_PROXY_ADMIN_ADDRESS:-}\","
  echo "  \"settlementProxy\": \"${SETTLEMENT_PROXY_ADDRESS:-}\","
  echo "  \"settlementProxyAdmin\": \"${SETTLEMENT_PROXY_ADMIN_ADDRESS:-}\","
  echo "  \"settlementImplementation\": \"${SETTLEMENT_IMPLEMENTATION_ADDRESS:-}\","
  echo "  \"upgradedSettlementImplementation\": \"${UPGRADED_SETTLEMENT_IMPLEMENTATION_ADDRESS:-}\","
  echo "  \"proxyAdminEnv\": \"${PROXY_ADMIN:-}\","
  echo "  \"settlementProxyEnv\": \"${SETTLEMENT_PROXY:-}\","
  echo "  \"proxyEnv\": \"${PROXY:-}\","
  echo "  \"faucetTokensRaw\": \"${FAUCET_TOKENS:-}\","
  echo "  \"mockTokens\": ${MOCK_TOKENS_JSON}"
  echo "}"
} > "$SUMMARY_FILE"

cp "$SUMMARY_FILE" "$LATEST_FILE"

echo "Deployment summary written to $SUMMARY_FILE"
echo "Latest deployment summary symlink at $LATEST_FILE"
echo "=== run-all.sh finished ==="
