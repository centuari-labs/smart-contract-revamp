#!/usr/bin/env bash

# Set supported tokens on the Treasury contract from the deployments JSON.
#
# For each token address in the configured token list (by default, `mockTokens`
# in the deployments JSON), this script calls:
#   Treasury.setSupportedToken(token, true)
#
# Requirements:
#   - Foundry CLI (`cast`) on PATH
#   - `jq` on PATH
#   - `.env` at the repo root providing:
#       - PRIVATE_KEY  -> EOA that has TOKEN_MANAGER_ROLE on Treasury
#   - Deployments JSON (default: deployments/deploy-unknown-latest.json) with:
#       - rpcUrl
#       - treasuryAddress
#       - mockTokens mapping OR use TOKENS_OVERRIDE
#
# Usage:
#   # Configure PRIVATE_KEY (and optionally DEPLOY_JSON, TOKENS_OVERRIDE, UNSUPPORT_MODE)
#   # in the project .env file, then run:
#   ./bin/set_supported_tokens.sh
#
# Environment variables:
#   - DEPLOY_JSON     : path to deployments JSON (default: deployments/deploy-unknown-latest.json)
#   - TOKENS_OVERRIDE : optional comma-separated list of token addresses to use
#                       instead of mockTokens from the JSON
#   - UNSUPPORT_MODE  : if set to "true", will call setSupportedToken(token, false)
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

# Allow overrides via environment variables; fall back to defaults/JSON.
DEPLOY_JSON="${DEPLOY_JSON:-deployments/deploy-unknown-latest.json}"

if [[ ! -f "$DEPLOY_JSON" ]]; then
  echo "Deployments JSON not found: $DEPLOY_JSON" >&2
  exit 1
fi

RPC_URL="$(jq -r '.rpcUrl' "$DEPLOY_JSON")"
TREASURY="$(jq -r '.treasuryAddress' "$DEPLOY_JSON")"
MANAGER_PK="${PRIVATE_KEY:-}"

if [[ -z "$RPC_URL" || "$RPC_URL" == "null" ]]; then
  echo "rpcUrl missing in $DEPLOY_JSON" >&2
  exit 1
fi

if [[ -z "$TREASURY" || "$TREASURY" == "null" ]]; then
  echo "treasuryAddress missing in $DEPLOY_JSON" >&2
  exit 1
fi

if [[ -z "$MANAGER_PK" || "$MANAGER_PK" == "null" ]]; then
  echo "PRIVATE_KEY environment variable is not set (needs TOKEN_MANAGER_ROLE)" >&2
  exit 1
fi

if ! command -v cast >/dev/null 2>&1; then
  echo "cast not found on PATH. Please install Foundry CLI." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq not found on PATH. Please install jq." >&2
  exit 1
fi

# Derive manager address from private key
MANAGER_ADDR="$(cast wallet address --private-key "$MANAGER_PK")"

echo "Using RPC_URL:         $RPC_URL"
echo "Using Treasury:        $TREASURY"
echo "Manager (TOKEN_MANAGER_ROLE) address: $MANAGER_ADDR"
echo "Deploy JSON:           $DEPLOY_JSON"
echo "UNSUPPORT_MODE:        ${UNSUPPORT_MODE:-false}"
echo

TOKENS=()

if [[ -n "${TOKENS_OVERRIDE:-}" ]]; then
  # Use comma-separated override list
  IFS=',' read -r -a TOKENS <<< "$TOKENS_OVERRIDE"
else
  # Collect token addresses from mockTokens mapping in the deployments JSON
  while IFS= read -r addr; do
    TOKENS+=("$addr")
  done < <(jq -r '.mockTokens | to_entries[] | .value' "$DEPLOY_JSON")
fi

if [[ "${#TOKENS[@]}" -eq 0 ]]; then
  echo "No tokens found to configure. Check TOKENS_OVERRIDE or .mockTokens in $DEPLOY_JSON" >&2
  exit 1
fi

echo "Found ${#TOKENS[@]} tokens to configure."
echo

# Determine whether we are enabling or disabling support
SUPPORTED_VALUE=true
if [[ "${UNSUPPORT_MODE:-false}" == "true" ]]; then
  SUPPORTED_VALUE=false
fi

for token in "${TOKENS[@]}"; do
  echo "=============================================="
  echo "Processing token: $token"
  echo "  Setting supported: $SUPPORTED_VALUE"

  # Call Treasury.setSupportedToken(token, supported)
  cast send "$TREASURY" "setSupportedToken(address,bool)" "$token" "$SUPPORTED_VALUE" \
    --private-key "$MANAGER_PK" \
    --rpc-url "$RPC_URL"

  # Optional verification step: read supportedToken(token) back
  echo "  Verifying supportedToken status..."
  supported_out="$(cast call "$TREASURY" "supportedToken(address)(bool)" "$token" --rpc-url "$RPC_URL")" || supported_out="<call failed>"
  echo "  supportedToken($token) = $supported_out"
  echo
done

echo "Done configuring supported tokens on Treasury."

