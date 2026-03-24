#!/usr/bin/env bash
#
# Sets up a matured market with a lend position on Anvil for E2E withdraw testing.
#
# Prerequisites:
#   - Anvil running on http://127.0.0.1:8545 (chain-id 31337)
#   - All contracts deployed via: RPC_URL=http://127.0.0.1:8545 ./bin/run-all.sh --broadcast
#   - PostgreSQL accessible via DATABASE_URL
#   - Foundry CLI (forge, cast) and jq on PATH
#
# Usage:
#   DATABASE_URL=postgresql://user:pass@localhost:5432/centuari ./bin/setup-mature-market.sh
#
# This script:
#   1. Reads deployment addresses from deployments JSON
#   2. Runs SetupMatureMarket.s.sol to settle a match on-chain
#   3. Fast-forwards Anvil time past maturity
#   4. Calls Centuari.repay() so Treasury has funds for withdrawal
#   5. Seeds the database with matching market + lend position
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

# Load .env if present
if [[ -f ".env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source ".env"
  set +a
fi

# ─── Configuration ───────────────────────────────────────────────────────────
RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
DEPLOY_JSON="${DEPLOY_JSON:-deployments/deploy-unknown-latest.json}"

# Anvil well-known private keys
DEPLOYER_PK="${DEPLOYER_PK:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
LENDER_PK="${LENDER_PK:-0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d}"
BORROWER_PK="${BORROWER_PK:-0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6}"
SETTLEMENT_OP_PK="${SETTLEMENT_OP_PK:-0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a}"

# ─── Dependency checks ───────────────────────────────────────────────────────
for cmd in cast forge jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: $cmd not found on PATH" >&2
    exit 1
  fi
done

if [[ -z "${DATABASE_URL:-}" ]]; then
  echo "Error: DATABASE_URL must be set" >&2
  exit 1
fi

if [[ ! -f "$DEPLOY_JSON" ]]; then
  echo "Error: Deployment JSON not found: $DEPLOY_JSON" >&2
  echo "Run './bin/run-all.sh --broadcast' first to deploy contracts." >&2
  exit 1
fi

# ─── Read deployment addresses ───────────────────────────────────────────────
SETTLEMENT_PROXY="$(jq -r '.settlementProxy' "$DEPLOY_JSON")"
TREASURY_ADDRESS="$(jq -r '.treasuryAddress' "$DEPLOY_JSON")"
CENTUARI_ADDRESS="$(jq -r '.centuariAddress' "$DEPLOY_JSON")"
USDC_ADDRESS="$(jq -r '.mockTokens.USDC' "$DEPLOY_JSON")"

LENDER_ADDR="$(cast wallet address --private-key "$LENDER_PK")"
BORROWER_ADDR="$(cast wallet address --private-key "$BORROWER_PK")"

echo "=== Setup Mature Market for E2E Withdraw Test ==="
echo "RPC:            $RPC_URL"
echo "Settlement:     $SETTLEMENT_PROXY"
echo "Treasury:       $TREASURY_ADDRESS"
echo "Centuari:       $CENTUARI_ADDRESS"
echo "USDC:           $USDC_ADDRESS"
echo "Lender:         $LENDER_ADDR"
echo "Borrower:       $BORROWER_ADDR"
echo

# ─── Step 1: Run SetupMatureMarket Foundry script ────────────────────────────
echo "=== Step 1/4: Settling match on-chain ==="
SETUP_OUTPUT=$(SETTLEMENT_PROXY="$SETTLEMENT_PROXY" \
  TREASURY_ADDRESS="$TREASURY_ADDRESS" \
  USDC_ADDRESS="$USDC_ADDRESS" \
  DEPLOYER_PK="$DEPLOYER_PK" \
  LENDER_PK="$LENDER_PK" \
  BORROWER_PK="$BORROWER_PK" \
  SETTLEMENT_OP_PK="$SETTLEMENT_OP_PK" \
  forge script script/SetupMatureMarket.s.sol:SetupMatureMarket \
    --rpc-url "$RPC_URL" \
    --broadcast \
    -vvv 2>&1) || {
  echo "$SETUP_OUTPUT"
  echo "SetupMatureMarket script failed" >&2
  exit 1
}
echo "$SETUP_OUTPUT"

# Parse the maturity timestamp from script output (BSD grep compatible)
MATURITY=$(echo "$SETUP_OUTPUT" | sed -n 's/.*MATURITY=\([0-9]*\).*/\1/p' | head -1)
MATCHED_AMOUNT=$(echo "$SETUP_OUTPUT" | sed -n 's/.*MATCHED_AMOUNT=\([0-9]*\).*/\1/p' | head -1)
CBT_AMOUNT=$(echo "$SETUP_OUTPUT" | sed -n 's/.*CBT_AMOUNT=\([0-9]*\).*/\1/p' | head -1)

if [[ -z "$MATURITY" ]]; then
  echo "Error: Could not parse MATURITY from script output" >&2
  exit 1
fi

echo
echo "Parsed: MATURITY=$MATURITY, MATCHED_AMOUNT=$MATCHED_AMOUNT, CBT_AMOUNT=$CBT_AMOUNT"

# ─── Step 2: Fast-forward Anvil time past maturity ───────────────────────────
echo
echo "=== Step 2/4: Fast-forwarding Anvil time ==="
cast rpc evm_increaseTime 300 --rpc-url "$RPC_URL" > /dev/null
cast rpc evm_mine --rpc-url "$RPC_URL" > /dev/null

# cast block returns timestamp as hex, convert to decimal
BLOCK_TS_HEX=$(cast block latest --rpc-url "$RPC_URL" -j | jq -r '.timestamp')
BLOCK_TS=$((BLOCK_TS_HEX))
echo "Current block timestamp: $BLOCK_TS (maturity was: $MATURITY)"

if [[ "$BLOCK_TS" -lt "$MATURITY" ]]; then
  echo "Error: Block timestamp ($BLOCK_TS) is still before maturity ($MATURITY)" >&2
  exit 1
fi
echo "Time warp successful — block is past maturity."

# ─── Step 3: Repay borrower debt so Treasury has funds for withdrawal ────────
echo
echo "=== Step 3/4: Repaying borrower debt ==="

# Compute marketId using cast (no node/viem dependency needed)
# abi.encode(address, uint256) then keccak256, then truncate upper 16 bytes
ABI_ENCODED=$(cast abi-encode "f(address,uint256)" "$USDC_ADDRESS" "$MATURITY")
FULL_HASH=$(cast keccak256 "$ABI_ENCODED")
# Truncate: keep first 32 hex chars (16 bytes), zero-pad lower 16 bytes
MARKET_ID_BYTES32="0x$(echo "$FULL_HASH" | sed 's/^0x//' | cut -c1-32)$(printf '%032d' 0)"

echo "MarketId (bytes32): $MARKET_ID_BYTES32"

# Centuari.repay(bytes32 marketId, address borrower, address loanToken, uint256 amount)
# Called by the Centuari operator (= backend operator = lender)
echo "Calling Centuari.repay..."
cast send "$CENTUARI_ADDRESS" \
  "repay(bytes32,address,address,uint256)" \
  "$MARKET_ID_BYTES32" "$BORROWER_ADDR" "$USDC_ADDRESS" "$CBT_AMOUNT" \
  --private-key "$LENDER_PK" \
  --rpc-url "$RPC_URL"

echo "Repay successful."

# ─── Step 4: Seed the database ───────────────────────────────────────────────
echo
echo "=== Step 4/4: Seeding database ==="

# Compute market UUID from the bytes32 (first 32 hex chars formatted as UUID)
HEX32=$(echo "$MARKET_ID_BYTES32" | sed 's/^0x//' | cut -c1-32)
MARKET_UUID="${HEX32:0:8}-${HEX32:8:4}-${HEX32:12:4}-${HEX32:16:4}-${HEX32:20:12}"

# Convert maturity unix timestamp to ISO string
if [[ "$(uname)" == "Darwin" ]]; then
  MATURITY_ISO=$(date -u -r "$MATURITY" +"%Y-%m-%dT%H:%M:%SZ")
else
  MATURITY_ISO=$(date -u -d "@$MATURITY" +"%Y-%m-%dT%H:%M:%SZ")
fi

SEED_SQL="$ROOT_DIR/../backend-v2/src/core/database/seeds/e2e/setup_mature_market_withdraw_test.sql"
if [[ ! -f "$SEED_SQL" ]]; then
  echo "Error: Seed SQL not found at $SEED_SQL" >&2
  exit 1
fi

echo "Market UUID:  $MARKET_UUID"
echo "Maturity ISO: $MATURITY_ISO"
echo "CBT Amount:   $CBT_AMOUNT"
echo "USDC Address: $USDC_ADDRESS"

psql "$DATABASE_URL" \
  -v market_uuid="$MARKET_UUID" \
  -v maturity_iso="$MATURITY_ISO" \
  -v lender_wallet="$LENDER_ADDR" \
  -v cbt_amount="$CBT_AMOUNT" \
  -v principal_amount="$MATCHED_AMOUNT" \
  -v usdc_address="$USDC_ADDRESS" \
  -f "$SEED_SQL"

echo
echo "=========================================="
echo "=== Setup Complete ==="
echo "=========================================="
echo
echo "Market UUID:      $MARKET_UUID"
echo "MarketId (hex):   $MARKET_ID_BYTES32"
echo "Maturity:         $MATURITY ($MATURITY_ISO)"
echo "Lender:           $LENDER_ADDR"
echo "CBT Amount:       $CBT_AMOUNT"
echo "USDC Address:     $USDC_ADDRESS"
echo
echo "Backend .env overrides for Anvil:"
echo "  SUPPORTED_CHAINS=31337"
echo "  RPC_31337=$RPC_URL"
echo "  CHAIN_ID=31337"
echo "  OPERATOR_PRIVATE_KEY=$LENDER_PK"
echo "  CENTUARI_ADDRESS=$CENTUARI_ADDRESS"
echo "  TREASURY_ADDRESS=$TREASURY_ADDRESS"
echo
echo "Playwright E2E command:"
echo "  LENDER_WALLET=$LENDER_ADDR API_BASE_URL=http://localhost:3001 pnpm run test:e2e -- withdraw-lend-position.spec.ts"
