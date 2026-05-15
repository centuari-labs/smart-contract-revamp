#!/usr/bin/env bash
#
# Deploy the three M5 spoke contracts (SpokeVaultStable, SpokePayout,
# SpokeDepositGateway) to a spoke chain via DeploySpokeContracts.s.sol.
#
# Usage:
#   CHAIN_ID=84532 ./bin/deploy-spoke.sh
#
# Required env vars:
#   CHAIN_ID           — EIP-155 chain id (e.g. 84532 for Base Sepolia)
#   SPOKE_RPC_URL      — RPC endpoint for the spoke chain
#   PRIVATE_KEY        — Deployer private key
#   OWNER              — Governance / multisig owner address
#   LZ_ENDPOINT        — LayerZero V2 endpoint address on the spoke chain
#   HUB_EID            — LayerZero endpoint id of the hub (e.g. 40231 for Arb Sepolia)
#   PROXY_ADMIN_OWNER  — Owner of each ProxyAdmin (e.g. multisig)
#
# Optional:
#   VERIFY             — set to "true" to verify on Etherscan
#   ETHERSCAN_API_KEY  — required if VERIFY=true
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

# Validate required env vars
: "${CHAIN_ID:?Set CHAIN_ID (e.g. 84532 for Base Sepolia)}"
: "${SPOKE_RPC_URL:?Set SPOKE_RPC_URL}"
: "${PRIVATE_KEY:?Set PRIVATE_KEY}"
: "${OWNER:?Set OWNER}"
: "${LZ_ENDPOINT:?Set LZ_ENDPOINT}"
: "${HUB_EID:?Set HUB_EID}"
: "${PROXY_ADMIN_OWNER:?Set PROXY_ADMIN_OWNER}"

VERIFY_FLAGS=""
if [[ "${VERIFY:-false}" == "true" ]]; then
  : "${ETHERSCAN_API_KEY:?Set ETHERSCAN_API_KEY for verification}"
  VERIFY_FLAGS="--verify --etherscan-api-key $ETHERSCAN_API_KEY"
fi

echo "=== Deploying Spoke Contracts ==="
echo "Chain ID:          $CHAIN_ID"
echo "RPC:               $SPOKE_RPC_URL"
echo "Owner:             $OWNER"
echo "LZ Endpoint:       $LZ_ENDPOINT"
echo "Hub EID:           $HUB_EID"
echo "ProxyAdmin Owner:  $PROXY_ADMIN_OWNER"
echo ""

# Run the deploy script
OUTPUT=$(forge script script/DeploySpokeContracts.s.sol \
  --sig 'run(address,address,uint32,address)' \
  "$OWNER" "$LZ_ENDPOINT" "$HUB_EID" "$PROXY_ADMIN_OWNER" \
  --rpc-url "$SPOKE_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast \
  $VERIFY_FLAGS \
  2>&1)

echo "$OUTPUT"

# Parse addresses from console.log output
parse_addr() {
  echo "$OUTPUT" | grep "$1" | awk '{print $NF}'
}

VAULT_PROXY=$(parse_addr "SpokeVaultStable proxy:")
VAULT_IMPL=$(parse_addr "SpokeVaultStable implementation:")
PAYOUT_PROXY=$(parse_addr "SpokePayout proxy:")
PAYOUT_IMPL=$(parse_addr "SpokePayout implementation:")
GATEWAY_PROXY=$(parse_addr "SpokeDepositGateway proxy:")
GATEWAY_IMPL=$(parse_addr "SpokeDepositGateway implementation:")

# Write deployment summary
DEPLOY_DIR="deployments"
mkdir -p "$DEPLOY_DIR"
DEPLOY_FILE="$DEPLOY_DIR/deploy-spoke-${CHAIN_ID}-latest.json"

cat > "$DEPLOY_FILE" <<EOF
{
  "chainId": $CHAIN_ID,
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "contracts": {
    "SpokeVaultStable": {
      "proxy": "$VAULT_PROXY",
      "implementation": "$VAULT_IMPL"
    },
    "SpokePayout": {
      "proxy": "$PAYOUT_PROXY",
      "implementation": "$PAYOUT_IMPL"
    },
    "SpokeDepositGateway": {
      "proxy": "$GATEWAY_PROXY",
      "implementation": "$GATEWAY_IMPL"
    }
  },
  "config": {
    "owner": "$OWNER",
    "lzEndpoint": "$LZ_ENDPOINT",
    "hubEid": $HUB_EID,
    "proxyAdminOwner": "$PROXY_ADMIN_OWNER"
  }
}
EOF

echo ""
echo "=== Deployment Summary ==="
echo "Written to: $DEPLOY_FILE"
cat "$DEPLOY_FILE"
echo ""
echo "Next steps:"
echo "  1. Run ConfigureHubForM5.s.sol on the hub to register these spoke contracts"
echo "  2. Run ./bin/export-abi.sh to update ABIs for M8/M9"
