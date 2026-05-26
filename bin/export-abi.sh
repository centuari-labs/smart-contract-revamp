#!/usr/bin/env bash
#
# Export ABI JSON from built contract artifacts into abi/<Contract>.json.
# Contracts: Centuari, BalanceLedger, HubDepositor, CollateralManager, Settlement, Faucet, CentuariBondERC20Factory.
#
# Usage:
#   ./bin/export-abi.sh
#
# Requires: forge (Foundry), jq, Node.js (for Prettier)
# Run from repo root. Runs 'forge build' if artifacts are missing.
# Formats output with Prettier for readability.
#
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

OUT_DIR="out"
ABI_DIR="abi"

# (SourceFile.sol, ContractName) pairs
CONTRACTS=(
  "Centuari.sol:Centuari"
  "BalanceLedger.sol:BalanceLedger"
  "HubDepositor.sol:HubDepositor"
  "CollateralManager.sol:CollateralManager"
  "Settlement.sol:Settlement"
  "Faucet.sol:Faucet"
  "CentuariBondERC20Factory.sol:CentuariBondERC20Factory"
  "WithdrawalRegistry.sol:WithdrawalRegistry"
  "HubIntentSettler.sol:HubIntentSettler"
  "SettlementLedger.sol:SettlementLedger"
  "SpokeVaultStable.sol:SpokeVaultStable"
  "SpokeDepositGateway.sol:SpokeDepositGateway"
  "SpokePayout.sol:SpokePayout"
  "OracleRouter.sol:OracleRouter"
  "RiskModule.sol:RiskModule"
  "PushOracle.sol:PushOracle"
  "ChainlinkPriceFeed.sol:ChainlinkPriceFeed"
)

# Ensure artifacts exist
if [[ ! -d "$OUT_DIR" ]] || [[ ! -f "$OUT_DIR/Centuari.sol/Centuari.json" ]]; then
  echo "Building contracts (forge build)..."
  forge build
fi

mkdir -p "$ABI_DIR"

for entry in "${CONTRACTS[@]}"; do
  IFS=: read -r src_file contract_name <<< "$entry"
  artifact="$OUT_DIR/$src_file/$contract_name.json"
  abi_file="$ABI_DIR/$contract_name.json"
  if [[ ! -f "$artifact" ]]; then
    echo "Error: artifact not found: $artifact" >&2
    exit 1
  fi
  jq '.abi' "$artifact" > "$abi_file"
  echo "Wrote $abi_file"
done

if command -v npx &>/dev/null; then
  echo "Formatting with Prettier..."
  npx --yes prettier --write "abi/*.json"
else
  echo "Skipping Prettier (npx not found). Install Node.js to format output."
fi

echo "Done. ABIs written to $ABI_DIR/"
