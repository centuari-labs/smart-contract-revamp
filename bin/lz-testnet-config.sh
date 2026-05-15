#!/usr/bin/env bash
# LayerZero V2 testnet endpoint + EID constants for the 5 chains used in Phase 1.
#
# Source this file from another bash script:
#   source "$(dirname "${BASH_SOURCE[0]}")/lz-testnet-config.sh"
#
# All 5 chains share the same EndpointV2 address (0x6EDCE65403992e310A62460808c4b910D972f10f)
# because LayerZero deploys the V2 endpoint to the same address across most EVM chains.
#
# Verified 2026-04-30 against:
#   https://metadata.layerzero-api.com/v1/metadata/deployments
# Cross-checked against per-chain docs at https://docs.layerzero.network/v2/deployments/chains/<chain>.
#
# If LayerZero rotates an endpoint or adds a new chain, regenerate by running:
#   curl -sL https://metadata.layerzero-api.com/v1/metadata/deployments | jq -r '
#     to_entries[] | .key as $c | (.value.deployments // [])[]
#     | select(.eid | tonumber | . >= 40000 and . < 41000)
#     | "\($c) | eid=\(.eid) | endpointV2=\(.endpointV2.address)"
#   '

# ---------------------------------------------------------------------------
# Shared EndpointV2 across all 5 testnets (LayerZero V2 unified deployment)
# ---------------------------------------------------------------------------
LZ_ENDPOINT_V2_ADDRESS="0x6EDCE65403992e310A62460808c4b910D972f10f"

# ---------------------------------------------------------------------------
# Hub: Arbitrum Sepolia (chain 421614)
# ---------------------------------------------------------------------------
LZ_ENDPOINT_ARB_SEPOLIA="$LZ_ENDPOINT_V2_ADDRESS"
LZ_EID_ARB_SEPOLIA=40231

# ---------------------------------------------------------------------------
# Spokes
# ---------------------------------------------------------------------------
# Base Sepolia (chain 84532)
LZ_ENDPOINT_BASE_SEPOLIA="$LZ_ENDPOINT_V2_ADDRESS"
LZ_EID_BASE_SEPOLIA=40245

# Ethereum Sepolia (chain 11155111)
LZ_ENDPOINT_ETH_SEPOLIA="$LZ_ENDPOINT_V2_ADDRESS"
LZ_EID_ETH_SEPOLIA=40161

# BNB Smart Chain Testnet (chain 97)
LZ_ENDPOINT_BNB_TESTNET="$LZ_ENDPOINT_V2_ADDRESS"
LZ_EID_BNB_TESTNET=40102

# Polygon Amoy (chain 80002)
LZ_ENDPOINT_POLYGON_AMOY="$LZ_ENDPOINT_V2_ADDRESS"
LZ_EID_POLYGON_AMOY=40267

# ---------------------------------------------------------------------------
# Convenience helper: print a summary table
# ---------------------------------------------------------------------------
lz_testnet_print_summary() {
  printf '%-18s %-10s %-12s %s\n' "CHAIN" "CHAIN_ID" "EID" "ENDPOINT_V2"
  printf '%-18s %-10s %-12s %s\n' "Arbitrum Sepolia"  "421614"   "$LZ_EID_ARB_SEPOLIA"     "$LZ_ENDPOINT_ARB_SEPOLIA"
  printf '%-18s %-10s %-12s %s\n' "Base Sepolia"      "84532"    "$LZ_EID_BASE_SEPOLIA"    "$LZ_ENDPOINT_BASE_SEPOLIA"
  printf '%-18s %-10s %-12s %s\n' "Ethereum Sepolia"  "11155111" "$LZ_EID_ETH_SEPOLIA"     "$LZ_ENDPOINT_ETH_SEPOLIA"
  printf '%-18s %-10s %-12s %s\n' "BNB Testnet"       "97"       "$LZ_EID_BNB_TESTNET"     "$LZ_ENDPOINT_BNB_TESTNET"
  printf '%-18s %-10s %-12s %s\n' "Polygon Amoy"      "80002"    "$LZ_EID_POLYGON_AMOY"    "$LZ_ENDPOINT_POLYGON_AMOY"
}

# Allow direct execution to print the summary
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  lz_testnet_print_summary
fi
