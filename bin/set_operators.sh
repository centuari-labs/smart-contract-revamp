#!/usr/bin/env bash

# Set operator addresses on Centuari, Settlement, and Faucet contracts
# using data from a deployments JSON file.
#
# For each contract, this script calls:
#   setOperator(address newOperator)  (onlyOwner)
# and then verifies via:
#   operator() -> address
#
# Requirements:
#   - Foundry CLI (`cast`) on PATH
#   - `jq` on PATH
#   - `.env` at the repo root providing:
#       - PRIVATE_KEY       -> EOA that is the owner of all contracts
#       - BACKEND_OPERATOR  -> Backend operator address (Centuari, Faucet)
#       - SETTLEMENT_OPERATOR -> Settlement operator address
#   - Deployments JSON with:
#       - rpcUrl
#       - centuariAddress
#       - settlementProxy
#       - faucetAddress
#
# Usage:
#   # Typically invoked from bin/run-all.sh, which sets DEPLOY_JSON.
#   # You can also run it directly:
#   #   DEPLOY_JSON=deployments/deploy-<network>-latest.json ./bin/set_operators.sh
#

set -euo pipefail

# Determine repo root and auto-load .env so the user doesn't need to export manually.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "$ROOT_DIR/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  . "$ROOT_DIR/.env"
  set +a
fi

# Allow overrides via environment variables; fall back to a sensible default.
DEPLOY_JSON="${DEPLOY_JSON:-deployments/deploy-unknown-latest.json}"

if [[ ! -f "$DEPLOY_JSON" ]]; then
  echo "Deployments JSON not found: $DEPLOY_JSON" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq not found on PATH. Please install jq." >&2
  exit 1
fi

if ! command -v cast >/dev/null 2>&1; then
  echo "cast not found on PATH. Please install Foundry CLI." >&2
  exit 1
fi

RPC_URL="$(jq -r '.rpcUrl' "$DEPLOY_JSON")"
CENTUARI_ADDR="$(jq -r '.centuariAddress' "$DEPLOY_JSON")"
SETTLEMENT_ADDR="$(jq -r '.settlementProxy' "$DEPLOY_JSON")"
FAUCET_ADDR="$(jq -r '.faucetAddress' "$DEPLOY_JSON")"
TREASURY_ADDR="$(jq -r '.treasuryAddress' "$DEPLOY_JSON")"

if [[ -z "$RPC_URL" || "$RPC_URL" == "null" ]]; then
  echo "rpcUrl missing in $DEPLOY_JSON" >&2
  exit 1
fi

OWNER_PK="${PRIVATE_KEY:-}"
if [[ -z "$OWNER_PK" || "$OWNER_PK" == "null" ]]; then
  echo "PRIVATE_KEY environment variable is not set (needs to be the owner EOA)" >&2
  exit 1
fi

echo "Using DEPLOY_JSON:      $DEPLOY_JSON"
echo "Using RPC_URL:          $RPC_URL"
echo "Centuari address:       $CENTUARI_ADDR"
echo "Settlement proxy:       $SETTLEMENT_ADDR"
echo "Faucet address:         $FAUCET_ADDR"
echo "Treasury address:       $TREASURY_ADDR"
echo

# Helper to set operator on a single contract.
set_operator_for_contract() {
  local label="$1"
  local addr="$2"
  local operator_env_var="$3"
  local getter="${4:-operator()}"

  # Indirect expansion to read env var by name.
  local operator_addr="${!operator_env_var-}"

  if [[ -z "$addr" || "$addr" == "null" ]]; then
    echo "[$label] Skipping: contract address missing in $DEPLOY_JSON"
    echo
    return 0
  fi

  if [[ -z "$operator_addr" || "$operator_addr" == "null" ]]; then
    echo "[$label] Skipping: $operator_env_var is not set"
    echo
    return 0
  fi

  echo "=============================================="
  echo "[$label] Setting operator"
  echo "  Contract:  $addr"
  echo "  Operator:  $operator_addr"
  echo "  Using key: PRIVATE_KEY (owner EOA)"

  # Send transaction to set operator.
  cast send "$addr" "setOperator(address)" "$operator_addr" \
    --private-key "$OWNER_PK" \
    --rpc-url "$RPC_URL"

  # Verify operator value.
  local getter="operator()"
  [[ "$label" == "Treasury" ]] && getter="getOperator()"

  echo "  Verifying $getter..."
  local current_operator
  if ! current_operator="$(cast call "$addr" "$getter" --rpc-url "$RPC_URL" 2>/dev/null)"; then
    current_operator="<call failed>"
  fi
  echo "  $getter = $current_operator"
  echo
}

# Centuari: BACKEND_OPERATOR
set_operator_for_contract "Centuari" "$CENTUARI_ADDR" "BACKEND_OPERATOR"

# Settlement: SETTLEMENT_OPERATOR
set_operator_for_contract "Settlement" "$SETTLEMENT_ADDR" "SETTLEMENT_OPERATOR"

# Faucet: BACKEND_OPERATOR
set_operator_for_contract "Faucet" "$FAUCET_ADDR" "BACKEND_OPERATOR"

# Treasury: TREASURY_OPERATOR
set_operator_for_contract "Treasury" "$TREASURY_ADDR" "TREASURY_OPERATOR"

echo "Done setting operators."

