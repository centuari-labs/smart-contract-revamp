#!/usr/bin/env bash
#
# transfer-ownership-to-multisig.sh — D1 mainnet-hardening governance handover.
#
# Moves Centuari governance off the deployer EOA onto a Safe multisig, in three tiers:
#   - guardian (pause/unpause)  -> Safe directly        (instant, no timelock)
#   - contract owner() (setters) -> 24h ops TimelockController
#   - ProxyAdmin (upgrades)      -> 48h upgrade TimelockController
# The Safe is proposer+executor on BOTH timelocks.
#
# Run AFTER a full bin/run-all.sh deploy, while the deployer EOA still owns
# everything (it must, to sign these transfers and the pre-transfer setPauser).
#
# Usage:
#   SAFE_ADDRESS=0x.. RPC_URL=.. PRIVATE_KEY=.. ./bin/transfer-ownership-to-multisig.sh [--network=<slug>]            # dry run (default, safe)
#   SAFE_ADDRESS=0x.. RPC_URL=.. PRIVATE_KEY=.. ./bin/transfer-ownership-to-multisig.sh --execute [--network=<slug>]  # broadcast
#
# Flags:
#   --execute            actually broadcast. WITHOUT it the script only prints the plan
#                        (current vs. target owner/pauser/ProxyAdmin) and changes nothing.
#   --network=<slug>     resolve the default deployment file (deployments/deploy-<slug>-latest.json).
#
# Env:
#   SAFE_ADDRESS  (required)            the Safe multisig (new guardian + timelock proposer/executor)
#   RPC_URL       (required)            target chain RPC
#   PRIVATE_KEY   (required for --execute) deployer key; MUST currently own every proxy + ProxyAdmin
#   OPS_DELAY     (optional, default 86400 = 24h)   operational-owner timelock delay; use e.g. 300 for testnet
#   UPGRADE_DELAY (optional, default 172800 = 48h)  upgrade timelock delay; use e.g. 600 for testnet
#   DEPLOY_JSON   (optional) explicit path to the deployment summary JSON
#
# NOTE: OwnableUpgradeable transfers are single-step and irreversible. Rehearse on
#       Arbitrum Sepolia first; double-check SAFE_ADDRESS before passing --execute.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

# Load .env (RPC_URL / PRIVATE_KEY / SAFE_ADDRESS may live there), like run-all.sh.
if [[ -f ".env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source ".env"
  set +a
fi

# ERC1967 admin slot: keccak256("eip1967.proxy.admin") - 1
ADMIN_SLOT="0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103"

EXECUTE=false
NETWORK_SLUG="${NETWORK_SLUG:-}"
for arg in "$@"; do
  case "$arg" in
    --execute) EXECUTE=true ;;
    --network=*) NETWORK_SLUG="${arg#*=}" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

OPS_DELAY="${OPS_DELAY:-86400}"
UPGRADE_DELAY="${UPGRADE_DELAY:-172800}"

command -v cast >/dev/null 2>&1 || { echo "error: 'cast' not found on PATH" >&2; exit 2; }
command -v jq   >/dev/null 2>&1 || { echo "error: 'jq' not found on PATH" >&2; exit 2; }

[[ -n "${SAFE_ADDRESS:-}" ]] || { echo "error: SAFE_ADDRESS is required" >&2; exit 2; }
[[ -n "${RPC_URL:-}" ]]      || { echo "error: RPC_URL is required" >&2; exit 2; }
if [[ "$EXECUTE" == true && -z "${PRIVATE_KEY:-}" ]]; then
  echo "error: PRIVATE_KEY is required with --execute" >&2; exit 2
fi

# Resolve the deployment summary.
if [[ -z "${DEPLOY_JSON:-}" ]]; then
  if [[ -z "$NETWORK_SLUG" ]]; then
    CHAIN_ID="$(cast chain-id "$RPC_URL" 2>/dev/null || true)"
    [[ -n "$CHAIN_ID" ]] && NETWORK_SLUG="chain-$CHAIN_ID"
  fi
  DEPLOY_JSON="$ROOT_DIR/deployments/deploy-${NETWORK_SLUG}-latest.json"
fi
[[ -f "$DEPLOY_JSON" ]] || { echo "error: deployment file not found: $DEPLOY_JSON (set DEPLOY_JSON or --network=<slug>)" >&2; exit 2; }
echo "Using deployment summary: $DEPLOY_JSON"

# Read a required address key from the summary.
read_addr() {
  local key="$1" val
  val="$(jq -r --arg k "$key" '.[$k] // ""' "$DEPLOY_JSON")"
  if [[ -z "$val" || "$val" == "null" || "$val" == "0x" ]]; then
    echo "error: deployment summary is missing '$key' — cannot continue" >&2
    exit 1
  fi
  echo "$val"
}

# All 11 upgradeable core proxies (owner() -> ops timelock; ProxyAdmin -> upgrade timelock).
BALANCE_LEDGER="$(read_addr balanceLedgerAddress)"
CENTUARI="$(read_addr centuariAddress)"
SETTLEMENT="$(read_addr settlementProxy)"
HUB_DEPOSITOR="$(read_addr hubDepositorAddress)"
COLLATERAL_MANAGER="$(read_addr collateralManagerAddress)"
WITHDRAWAL_REGISTRY="$(read_addr withdrawalRegistryAddress)"
HUB_INTENT_SETTLER="$(read_addr hubIntentSettlerAddress)"
SETTLEMENT_LEDGER="$(read_addr settlementLedgerAddress)"
RISK_MODULE="$(read_addr riskModuleAddress)"
ORACLE_ROUTER="$(read_addr oracleRouterAddress)"
LIQUIDATION_ENGINE="$(read_addr liquidationEngineAddress)"

PROXIES=(
  "$BALANCE_LEDGER" "$CENTUARI" "$SETTLEMENT" "$HUB_DEPOSITOR"
  "$COLLATERAL_MANAGER" "$WITHDRAWAL_REGISTRY" "$HUB_INTENT_SETTLER" "$SETTLEMENT_LEDGER"
  "$RISK_MODULE" "$ORACLE_ROUTER" "$LIQUIDATION_ENGINE"
)

# The 6 pausable contracts gain the fast Safe guardian (pause/unpause).
PAUSABLE=(
  "$BALANCE_LEDGER" "$CENTUARI" "$SETTLEMENT" "$WITHDRAWAL_REGISTRY" "$HUB_INTENT_SETTLER"
  "$LIQUIDATION_ENGINE"
)

# Derive each proxy's ProxyAdmin from the ERC1967 admin slot — the single source of
# truth, independent of whether the summary captured it.
derive_proxy_admin() {
  cast parse-bytes32-address "$(cast storage "$1" "$ADMIN_SLOT" --rpc-url "$RPC_URL")"
}

PROXY_ADMINS=()
for p in "${PROXIES[@]}"; do
  PROXY_ADMINS+=("$(derive_proxy_admin "$p")")
done

owner_of()  { cast call "$1" "owner()(address)"  --rpc-url "$RPC_URL" 2>/dev/null || echo "<call failed>"; }
pauser_of() { cast call "$1" "pauser()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "<call failed>"; }

echo
echo "=== Handover plan ==="
echo "Safe (guardian + timelock proposer/executor): $SAFE_ADDRESS"
echo "Ops timelock delay:     ${OPS_DELAY}s    (contract owner / setters)"
echo "Upgrade timelock delay: ${UPGRADE_DELAY}s (ProxyAdmin / upgrades)"
echo
printf '%-22s %-44s %-44s\n' "contract" "current owner()" "current ProxyAdmin"
NAMES=(BalanceLedger Centuari Settlement HubDepositor CollateralManager WithdrawalRegistry HubIntentSettler SettlementLedger RiskModule OracleRouter LiquidationEngine)
for i in "${!PROXIES[@]}"; do
  printf '%-22s %-44s %-44s\n' "${NAMES[$i]}" "$(owner_of "${PROXIES[$i]}")" "${PROXY_ADMINS[$i]}"
done
echo
echo "Pauser (guardian) targets -> $SAFE_ADDRESS:"
for p in "${PAUSABLE[@]}"; do
  printf '  %-44s current pauser: %s\n' "$p" "$(pauser_of "$p")"
done

if [[ "$EXECUTE" != true ]]; then
  echo
  echo "DRY RUN — nothing broadcast. Re-run with --execute to perform the handover."
  exit 0
fi

echo
echo ">>> EXECUTING handover (irreversible) <<<"

FORGE=(forge script --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --broadcast)

# 1. Deploy the two timelocks (Safe = proposer + executor on both).
echo "=== Deploying ops TimelockController (${OPS_DELAY}s) ==="
ops_out=$("${FORGE[@]}" script/timelock/DeployTimeLock.s.sol:DeployTimeLock \
  --sig "run(uint256,address,address)" "$OPS_DELAY" "$SAFE_ADDRESS" "$SAFE_ADDRESS" 2>&1)
echo "$ops_out"
OPS_TIMELOCK="$(echo "$ops_out" | grep -oE 'TimeLock address: 0x[a-fA-F0-9]{40}' | head -1 | awk '{print $3}')"
[[ -n "$OPS_TIMELOCK" ]] || { echo "error: could not parse ops TimeLock address" >&2; exit 1; }
echo "Ops TimeLock: $OPS_TIMELOCK"

echo "=== Deploying upgrade TimelockController (${UPGRADE_DELAY}s) ==="
up_out=$("${FORGE[@]}" script/timelock/DeployTimeLock.s.sol:DeployTimeLock \
  --sig "run(uint256,address,address)" "$UPGRADE_DELAY" "$SAFE_ADDRESS" "$SAFE_ADDRESS" 2>&1)
echo "$up_out"
UPGRADE_TIMELOCK="$(echo "$up_out" | grep -oE 'TimeLock address: 0x[a-fA-F0-9]{40}' | head -1 | awk '{print $3}')"
[[ -n "$UPGRADE_TIMELOCK" ]] || { echo "error: could not parse upgrade TimeLock address" >&2; exit 1; }
echo "Upgrade TimeLock: $UPGRADE_TIMELOCK"

# 2. Hand the guardian role to the Safe (while deployer is still owner).
echo "=== setPauser(Safe) on the 6 pausable contracts ==="
for p in "${PAUSABLE[@]}"; do
  echo "  setPauser($SAFE_ADDRESS) on $p"
  cast send "$p" "setPauser(address)" "$SAFE_ADDRESS" --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null
done

# 3. Move contract owner() -> ops timelock.
PROXY_ARRAY="[$(IFS=,; echo "${PROXIES[*]}")]"
echo "=== TransferContractOwnership -> ops timelock ==="
"${FORGE[@]}" script/timelock/TransferContractOwnership.s.sol:TransferContractOwnership \
  --sig "run(address,address[])" "$OPS_TIMELOCK" "$PROXY_ARRAY"

# 4. Move ProxyAdmin -> upgrade timelock.
ADMIN_ARRAY="[$(IFS=,; echo "${PROXY_ADMINS[*]}")]"
echo "=== TransferProxyAdminOwnership -> upgrade timelock ==="
"${FORGE[@]}" script/timelock/TransferProxyAdminOwnership.s.sol:TransferProxyAdminOwnership \
  --sig "run(address,address[])" "$UPGRADE_TIMELOCK" "$ADMIN_ARRAY"

echo
echo "=== Handover complete ==="
echo "Ops TimeLock (owner / 24h):     $OPS_TIMELOCK"
echo "Upgrade TimeLock (admin / 48h): $UPGRADE_TIMELOCK"
echo "Guardian (pause):               $SAFE_ADDRESS"
echo "Verify with: cast call <proxy> 'owner()(address)' / 'pauser()(address)' and cast call <proxyAdmin> 'owner()(address)'"
