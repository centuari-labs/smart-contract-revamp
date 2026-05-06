#!/usr/bin/env bash

# Mint all deployed mock tokens to a user EOA, then approve and deposit into Treasury.
#
# Requires:
#   - Foundry CLI (`cast`) on PATH
#   - `jq` on PATH
#   - Python 3 or Node.js for big integer math (used to compute 1_000_000 * 10^decimals)
#
# Usage:
#   # Put operator PRIVATE_KEY (and optional overrides) in the project .env file.
#   # Put userPk in config/keys.json (the address that will receive tokens and deposit into Treasury).
#   # Then simply run:
#   ./bin/mint_and_deposit.sh
#
# Flow:
#   - Auto-load environment variables from the project .env (including operator PRIVATE_KEY).
#   - Read rpcUrl, treasuryAddress, mockTokens from deployments JSON.
#   - Read userPk from config/keys.json (recipient/depositor EOA).
#   - For each mock token:
#       1) Operator (PRIVATE_KEY) mints to the user EOA via MockToken.mint.
#       2) User EOA approves Treasury.
#       3) User EOA calls ITreasury.deposit(token, amount).

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
KEYS_JSON="${KEYS_JSON:-config/keys.json}"
MODE="${SCRIPT_MODE:-}" # optional: --mint-only or --deposit-only

if [[ ! -f "$DEPLOY_JSON" ]]; then
  echo "Deployments JSON not found: $DEPLOY_JSON" >&2
  exit 1
fi

if [[ ! -f "$KEYS_JSON" ]]; then
  echo "Keys JSON not found: $KEYS_JSON" >&2
  exit 1
fi

RPC_URL="$(jq -r '.rpcUrl' "$DEPLOY_JSON")"
TREASURY="$(jq -r '.treasuryAddress' "$DEPLOY_JSON")"
OPERATOR_PK="${PRIVATE_KEY:-}"
USER_PK="$(jq -r '.userPk' "$KEYS_JSON")"

if [[ -z "$RPC_URL" || "$RPC_URL" == "null" ]]; then
  echo "rpcUrl missing in $DEPLOY_JSON" >&2
  exit 1
fi

if [[ -z "$TREASURY" || "$TREASURY" == "null" ]]; then
  echo "treasuryAddress missing in $DEPLOY_JSON" >&2
  exit 1
fi

if [[ -z "$OPERATOR_PK" || "$OPERATOR_PK" == "null" ]]; then
  echo "Operator PRIVATE_KEY environment variable is not set" >&2
  exit 1
fi

if [[ -z "$USER_PK" || "$USER_PK" == "null" ]]; then
  echo "userPk missing in $KEYS_JSON" >&2
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

# Derive addresses from private keys
OPERATOR_ADDR="$(cast wallet address --private-key "$OPERATOR_PK")"
USER_ADDR="$(cast wallet address --private-key "$USER_PK")"

echo "Using RPC_URL:       $RPC_URL"
echo "Using Treasury:      $TREASURY"
echo "Operator address:    $OPERATOR_ADDR"
echo "User address:        $USER_ADDR"
echo "Mode flag:           ${MODE:-<none>}"
echo

# Collect token addresses from mockTokens mapping
TOKENS=()
while IFS= read -r addr; do
  TOKENS+=("$addr")
done < <(jq -r '.mockTokens | to_entries[] | .value' "$DEPLOY_JSON")

if [[ "${#TOKENS[@]}" -eq 0 ]]; then
  echo "No mockTokens found in $DEPLOY_JSON" >&2
  exit 1
fi

echo "Found ${#TOKENS[@]} mock tokens to process."
echo

# Helper: compute 1_000_000 * 10^dec using python or node
compute_amount() {
  local dec="$1"

  if command -v python3 >/dev/null 2>&1; then
    python3 - <<EOF
dec = int("$dec")
amount = 1_000_000 * (10 ** dec)
print(amount)
EOF
  elif command -v python >/dev/null 2>&1; then
    python - <<EOF
dec = int("$dec")
amount = 1_000_000 * (10 ** dec)
print(amount)
EOF
  elif command -v node >/dev/null 2>&1; then
    node -e "const dec=parseInt('$dec',10); console.log((BigInt(1000000) * (10n ** BigInt(dec))).toString());"
  else
    echo "Error: python3/python/node not found for big integer math." >&2
    exit 1
  fi
}

for token in "${TOKENS[@]}"; do
  echo "=============================================="
  echo "Processing token: $token"

  # 1) Read decimals
  dec=""
  if dec_out=$(cast call "$token" "decimals()(uint8)" --rpc-url "$RPC_URL" 2>/dev/null); then
    dec="$dec_out"
  fi

  if [[ -z "$dec" ]]; then
    echo "  decimals() call failed, defaulting to 18"
    dec=18
  else
    echo "  decimals: $dec"
  fi

  # 2) Compute amount
  amount="$(compute_amount "$dec")"
  echo "  amount (1_000_000 * 10^$dec): $amount"

  # 3) Optional mint step
  if [[ "$MODE" != "--deposit-only" ]]; then
    echo "  Minting via MockToken.mint from operator..."
    cast send "$token" "mint(address,uint256)" "$USER_ADDR" "$amount" \
      --private-key "$OPERATOR_PK" \
      --rpc-url "$RPC_URL"

    wallet_after_mint="$(cast call "$token" "balanceOf(address)(uint256)" "$USER_ADDR" --rpc-url "$RPC_URL")"
    echo "  Wallet balance after mint: $wallet_after_mint"
  else
    echo "  --deposit-only mode: skipping mint."
  fi

  # 4) Optional approve + deposit
  if [[ "$MODE" != "--mint-only" ]]; then
    echo "  Approving Treasury for amount..."
    cast send "$token" "approve(address,uint256)" "$TREASURY" "$amount" \
      --private-key "$USER_PK" \
      --rpc-url "$RPC_URL"

    echo "  Calling Treasury.deposit..."
    cast send "$TREASURY" "deposit(address,uint256)" "$token" "$amount" \
      --private-key "$USER_PK" \
      --rpc-url "$RPC_URL"

    treasury_balance="$(cast call "$TREASURY" "balanceOf(address,address)(uint256)" "$USER_ADDR" "$token" --rpc-url "$RPC_URL")"
    wallet_after_deposit="$(cast call "$token" "balanceOf(address)(uint256)" "$USER_ADDR" --rpc-url "$RPC_URL")"
    echo "  Treasury internal balance: $treasury_balance"
    echo "  Wallet balance after deposit: $wallet_after_deposit"
  else
    echo "  --mint-only mode: skipping approve + deposit."
  fi

  echo
done

echo "Done processing all mock tokens."

