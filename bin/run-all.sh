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
#   PRIVATE_KEY          - Private key for the deployer (used when set)
#   OPERATOR_ADDRESS     - Optional. Used as FAUCET_OPERATOR and SETTLEMENT_OPERATOR when those are unset
#   FAUCET_OPERATOR      - Optional. Backend address for Faucet operator; else msg.sender (or OPERATOR_ADDRESS)
#   FAUCET_TOKENS        - Optional. Comma-separated token addresses to wire to Faucet (grant minter + addToken)
#   SETTLEMENT_OWNER     - Required for DeployCentuari and DeploySettlement. Owner (and default CENTUARI_OWNER)
#   SETTLEMENT_OPERATOR  - Required to run DeploySettlement. Settlement engine operator (or OPERATOR_ADDRESS)
#   CENTUARI_OWNER       - Optional. Centuari owner; defaults to SETTLEMENT_OWNER
#   CENTUARI_SETTLEMENT_PLACEHOLDER - Optional. Centuari init settlement; defaults to CENTUARI_OWNER
#   TREASURY_ADDRESS     - Optional. If set, skip DeployTreasury and use this for DeployCentuari / setCentuariContract
#   CENTUARI_ADDRESS     - Optional. If set, skip DeployCentuari and use this for setCentuariContract / DeploySettlement
#   PROXY_ADMIN_OWNER    - Required for DeployCentuari and DeploySettlement. Owner of the ProxyAdmin (e.g. multisig)
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

# Optional: OPERATOR_ADDRESS applies to FAUCET_OPERATOR and SETTLEMENT_OPERATOR when those are unset
[[ -z "${FAUCET_OPERATOR:-}" && -n "${OPERATOR_ADDRESS:-}" ]] && export FAUCET_OPERATOR="$OPERATOR_ADDRESS"
[[ -z "${SETTLEMENT_OPERATOR:-}" && -n "${OPERATOR_ADDRESS:-}" ]] && export SETTLEMENT_OPERATOR="$OPERATOR_ADDRESS"

# Defaults for Centuari deploy
[[ -z "${CENTUARI_OWNER:-}" && -n "${SETTLEMENT_OWNER:-}" ]] && export CENTUARI_OWNER="$SETTLEMENT_OWNER"
[[ -z "${CENTUARI_SETTLEMENT_PLACEHOLDER:-}" && -n "${CENTUARI_OWNER:-}" ]] && export CENTUARI_SETTLEMENT_PLACEHOLDER="$CENTUARI_OWNER"

# Base forge script command fragment (rpc and key when set)
FORGE_BASE=(forge script)
[[ -n "${RPC_URL:-}" ]] && FORGE_BASE+=(--rpc-url "$RPC_URL")
[[ -n "${PRIVATE_KEY:-}" ]] && FORGE_BASE+=(--private-key "$PRIVATE_KEY")

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

echo "=== 1/7 DeployMockTokens ==="
run_script script/DeployMockTokens.s.sol:DeployMockTokens

echo "=== 2/7 DeployFaucet ==="
run_script script/DeployFaucet.s.sol:DeployFaucet

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
if [[ -n "${SETTLEMENT_OWNER:-}" && -n "${PROXY_ADMIN_OWNER:-}" && -n "${TREASURY_ADDRESS:-}" ]]; then
  if [[ -z "${CENTUARI_ADDRESS:-}" ]]; then
    out=$(run_script script/DeployCentuari.s.sol:DeployCentuari \
      --sig "run(address,address,address,address)" \
      "$CENTUARI_OWNER" "$CENTUARI_SETTLEMENT_PLACEHOLDER" "$TREASURY_ADDRESS" "$PROXY_ADMIN_OWNER" 2>&1)
    echo "$out"
    CENTUARI=$(echo "$out" | parse_centuari_proxy)
    if [[ -n "$CENTUARI" ]]; then
      export CENTUARI_ADDRESS="$CENTUARI"
      echo "Captured CENTUARI_ADDRESS=$CENTUARI_ADDRESS"
    fi
  else
    echo "Using existing CENTUARI_ADDRESS=$CENTUARI_ADDRESS (skip deploy)"
  fi
else
  echo "Skipping DeployCentuari (set SETTLEMENT_OWNER, PROXY_ADMIN_OWNER and TREASURY_ADDRESS to run, or CENTUARI_ADDRESS to use existing)"
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
if [[ -n "${SETTLEMENT_OWNER:-}" && -n "${SETTLEMENT_OPERATOR:-}" && -n "${CENTUARI_ADDRESS:-}" && -n "${PROXY_ADMIN_OWNER:-}" ]]; then
  run_script script/DeploySettlement.s.sol:DeploySettlement \
    --sig "run(address,address,address,address)" \
    "$SETTLEMENT_OWNER" "$SETTLEMENT_OPERATOR" "$CENTUARI_ADDRESS" "$PROXY_ADMIN_OWNER"
else
  echo "Skipping DeploySettlement (set SETTLEMENT_OWNER, SETTLEMENT_OPERATOR, CENTUARI_ADDRESS, PROXY_ADMIN_OWNER to run)"
fi

echo "=== 7/7 UpgradeSettlement ==="
PROXY="${SETTLEMENT_PROXY:-${PROXY:-}}"
if [[ "$DEPLOY_ONLY" == true ]]; then
  echo "Skipping UpgradeSettlement (--deploy-only)"
elif [[ -n "${PROXY_ADMIN:-}" && -n "$PROXY" ]]; then
  run_script script/UpgradeSettlement.s.sol:UpgradeSettlement \
    --sig "run(address,address)" \
    "$PROXY_ADMIN" "$PROXY"
else
  echo "Skipping UpgradeSettlement (set PROXY_ADMIN and SETTLEMENT_PROXY or PROXY to run)"
fi

echo "=== run-all.sh finished ==="
