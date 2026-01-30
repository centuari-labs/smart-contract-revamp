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
#   SETTLEMENT_OWNER     - Required to run DeploySettlement. Owner of the Settlement contract
#   SETTLEMENT_OPERATOR  - Required to run DeploySettlement. Settlement engine operator (or OPERATOR_ADDRESS)
#   CENTUARI_ADDRESS     - Required to run DeploySettlement. Centuari contract address
#   PROXY_ADMIN_OWNER    - Required to run DeploySettlement. Owner of the ProxyAdmin (e.g. multisig)
#   PROXY_ADMIN          - Required to run UpgradeSettlement. ProxyAdmin contract address
#   SETTLEMENT_PROXY     - Required to run UpgradeSettlement. Settlement proxy address (alias: PROXY)
#
# DeploySettlement is skipped if any of SETTLEMENT_OWNER, SETTLEMENT_OPERATOR, CENTUARI_ADDRESS,
# PROXY_ADMIN_OWNER is unset. UpgradeSettlement is skipped if PROXY_ADMIN or SETTLEMENT_PROXY/PROXY
# is unset, or when --deploy-only is passed.
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

# Optional: OPERATOR_ADDRESS applies to FAUCET_OPERATOR and SETTLEMENT_OPERATOR when they are unset
[[ -z "${FAUCET_OPERATOR:-}" && -n "${OPERATOR_ADDRESS:-}" ]] && export FAUCET_OPERATOR="$OPERATOR_ADDRESS"
[[ -z "${SETTLEMENT_OPERATOR:-}" && -n "${OPERATOR_ADDRESS:-}" ]] && export SETTLEMENT_OPERATOR="$OPERATOR_ADDRESS"

# Base forge script command fragment (rpc and key when set)
FORGE_BASE=(forge script)
[[ -n "${RPC_URL:-}" ]] && FORGE_BASE+=(--rpc-url "$RPC_URL")
[[ -n "${PRIVATE_KEY:-}" ]] && FORGE_BASE+=(--private-key "$PRIVATE_KEY")

run_script() {
  "${FORGE_BASE[@]}" "$@" "${FORGE_EXTRA[@]}"
}

echo "=== 1/4 DeployMockTokens ==="
run_script script/DeployMockTokens.s.sol:DeployMockTokens

echo "=== 2/4 DeployFaucet ==="
run_script script/DeployFaucet.s.sol:DeployFaucet

echo "=== 3/4 DeploySettlement ==="
if [[ -n "${SETTLEMENT_OWNER:-}" && -n "${SETTLEMENT_OPERATOR:-}" && -n "${CENTUARI_ADDRESS:-}" && -n "${PROXY_ADMIN_OWNER:-}" ]]; then
  run_script script/DeploySettlement.s.sol:DeploySettlement \
    --sig "run(address,address,address,address)" \
    "$SETTLEMENT_OWNER" "$SETTLEMENT_OPERATOR" "$CENTUARI_ADDRESS" "$PROXY_ADMIN_OWNER"
else
  echo "Skipping DeploySettlement (set SETTLEMENT_OWNER, SETTLEMENT_OPERATOR, CENTUARI_ADDRESS, PROXY_ADMIN_OWNER to run)"
fi

echo "=== 4/4 UpgradeSettlement ==="
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
