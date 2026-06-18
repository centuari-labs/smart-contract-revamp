#!/usr/bin/env bash
#
# deploy-hardened.sh — secure-by-construction mainnet deploy path.
#
# Thin wrapper that makes governance hardening PART of the deploy instead of a
# separate, forgettable step. It runs the testnet-proven deploy core, hands all
# governance to a Safe + two TimelockControllers, then verifies the result — and
# only "succeeds" if the deployer EOA ends up owning NOTHING.
#
#   1. pre-flight   fail-closed checks (real multi-sig Safe, mainnet ack, verify key)
#   2. deploy       ./bin/run-all.sh            (shared core — UNEDITED)
#   3. handover     ./bin/transfer-ownership-to-multisig.sh   (timelocks + owner/admin/pauser)
#   4. verify       every proxy owner/admin -> timelocks, pausers -> Safe, deployer -> nothing
#
# Because it is chain-parameterised (RPC_URL + OPS_DELAY/UPGRADE_DELAY), the SAME
# script runs the Sepolia rehearsal (short delays) and the real Arbitrum One run.
#
# Usage:
#   SAFE_ADDRESS=0x.. RPC_URL=.. ./bin/deploy-hardened.sh                 # preview (default, safe)
#   SAFE_ADDRESS=0x.. RPC_URL=.. PRIVATE_KEY=.. ./bin/deploy-hardened.sh --execute              # broadcast (testnet)
#   SAFE_ADDRESS=0x.. RPC_URL=.. PRIVATE_KEY=.. ETHERSCAN_API_KEY=.. \
#     ./bin/deploy-hardened.sh --execute --mainnet-ack                    # broadcast (Arbitrum One)
#
# Flags:
#   --execute        actually deploy + hand over governance. WITHOUT it, nothing is
#                    broadcast: the script validates the Safe and prints the plan.
#   --mainnet-ack    required acknowledgement to broadcast against Arbitrum One (42161).
#   --network=<slug> deployment-file slug. Defaults to NETWORK_NAME, else chain-<id>.
#
# Env:
#   SAFE_ADDRESS  (required)            multi-sig Safe — new guardian + timelock proposer/executor
#   RPC_URL       (required)            target chain RPC
#   PRIVATE_KEY   (required for --execute) deployer key; must own everything pre-handover
#   ETHERSCAN_API_KEY (required on mainnet --execute) Arbiscan verification key
#   OPS_DELAY     (optional, default 86400 = 24h)   owner/setter timelock delay (use 300 on testnet)
#   UPGRADE_DELAY (optional, default 172800 = 48h)  ProxyAdmin/upgrade timelock delay (use 600 on testnet)
#
# NOTE: ownership transfers are single-step and IRREVERSIBLE. A wrong/weak Safe
#       permanently bricks governance — the pre-flight rejects a non-Safe or a
#       1-of-N Safe before anything is broadcast. Rehearse on Sepolia first.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

# Load .env (RPC_URL / PRIVATE_KEY / SAFE_ADDRESS may live there), like the sibling scripts.
if [[ -f ".env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source ".env"
  set +a
fi

# ERC1967 admin slot: keccak256("eip1967.proxy.admin") - 1
ADMIN_SLOT="0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103"
ARBITRUM_ONE_CHAIN_ID="42161"

die() { echo "error: $*" >&2; exit 1; }
lc()  { tr '[:upper:]' '[:lower:]'; }

EXECUTE=false
MAINNET_ACK=false
NETWORK_SLUG="${NETWORK_SLUG:-}"
for arg in "$@"; do
  case "$arg" in
    --execute)      EXECUTE=true ;;
    --mainnet-ack)  MAINNET_ACK=true ;;
    --network=*)    NETWORK_SLUG="${arg#*=}" ;;
    -h|--help)      sed -n '2,46p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)              die "unknown argument: $arg (try --help)" ;;
  esac
done

OPS_DELAY="${OPS_DELAY:-86400}"
UPGRADE_DELAY="${UPGRADE_DELAY:-172800}"

command -v cast >/dev/null 2>&1 || die "'cast' not found on PATH"
command -v jq   >/dev/null 2>&1 || die "'jq' not found on PATH"

[[ -n "${SAFE_ADDRESS:-}" ]] || die "SAFE_ADDRESS is required"
[[ -n "${RPC_URL:-}" ]]      || die "RPC_URL is required"

# Resolve chain id + deployment slug. Keep all three consumers (run-all, handover,
# verify) on the SAME slug by exporting NETWORK_NAME so run-all derives an identical name.
CHAIN_ID="$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null || true)"
[[ -n "$CHAIN_ID" ]] || die "could not read chain id from RPC_URL"
if [[ -z "$NETWORK_SLUG" ]]; then
  NETWORK_SLUG="${NETWORK_NAME:-chain-$CHAIN_ID}"
fi
export NETWORK_NAME="$NETWORK_SLUG"

# ---- Safe validation: a real multi-sig, not an EOA / typo / wrong-network address ----
SAFE_CODE="$(cast code "$SAFE_ADDRESS" --rpc-url "$RPC_URL" 2>/dev/null || echo "0x")"
[[ -n "$SAFE_CODE" && "$SAFE_CODE" != "0x" ]] \
  || die "SAFE_ADDRESS ($SAFE_ADDRESS) has no bytecode on chain $CHAIN_ID — not a deployed Safe (EOA / typo / wrong network?)"

SAFE_THRESHOLD="$(cast call "$SAFE_ADDRESS" "getThreshold()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "")"
SAFE_OWNERS="$(cast call "$SAFE_ADDRESS" "getOwners()(address[])" --rpc-url "$RPC_URL" 2>/dev/null || echo "")"
[[ -n "$SAFE_THRESHOLD" && -n "$SAFE_OWNERS" ]] \
  || die "SAFE_ADDRESS ($SAFE_ADDRESS) is a contract but does not respond to getThreshold()/getOwners() — not a Gnosis Safe"

SAFE_OWNER_COUNT="$(printf '%s' "$SAFE_OWNERS" | grep -oE '0x[a-fA-F0-9]{40}' | wc -l | tr -d ' ')"
# A 1-of-1 Safe re-creates the single-key risk the whole handover exists to remove.
(( SAFE_THRESHOLD >= 2 )) \
  || die "SAFE_ADDRESS threshold is $SAFE_THRESHOLD — refusing a <2 signing threshold (would re-create single-key risk)"
(( SAFE_OWNER_COUNT >= 2 )) \
  || die "SAFE_ADDRESS has $SAFE_OWNER_COUNT owner(s) — refusing a <2 owner Safe"

# ---- Mainnet gate ----
IS_MAINNET=false
if [[ "$CHAIN_ID" == "$ARBITRUM_ONE_CHAIN_ID" ]]; then
  IS_MAINNET=true
fi

echo "=== deploy-hardened ==="
echo "Chain id:               $CHAIN_ID $( [[ "$IS_MAINNET" == true ]] && echo '(ARBITRUM ONE — MAINNET)' )"
echo "Deployment slug:        $NETWORK_SLUG"
echo "Safe (guardian+timelock proposer/executor): $SAFE_ADDRESS  [${SAFE_THRESHOLD}-of-${SAFE_OWNER_COUNT}]"
echo "Ops timelock delay:     ${OPS_DELAY}s   (contract owner / setters)"
echo "Upgrade timelock delay: ${UPGRADE_DELAY}s (ProxyAdmin / upgrades)"
echo "Mode:                   $( [[ "$EXECUTE" == true ]] && echo 'EXECUTE (broadcast)' || echo 'preview (no broadcast)' )"

if [[ "$EXECUTE" == true ]]; then
  [[ -n "${PRIVATE_KEY:-}" ]] || die "PRIVATE_KEY is required with --execute"
  DEPLOYER="$(cast wallet address "$PRIVATE_KEY")"
  echo "Deployer EOA:           $DEPLOYER"

  if [[ "$IS_MAINNET" == true ]]; then
    [[ -n "${ETHERSCAN_API_KEY:-}" ]] \
      || die "ETHERSCAN_API_KEY is required on Arbitrum One (mainnet contracts must be verified)"
    if [[ "$MAINNET_ACK" != true ]]; then
      if [[ -t 0 ]]; then
        read -r -p "About to deploy + hand over governance on Arbitrum One. Type ARBITRUM-ONE to continue: " reply
        [[ "$reply" == "ARBITRUM-ONE" ]] || die "mainnet acknowledgement not given"
      else
        die "Arbitrum One requires --mainnet-ack (non-interactive shell)"
      fi
    fi
  elif [[ -z "${ETHERSCAN_API_KEY:-}" ]]; then
    echo "Warning: ETHERSCAN_API_KEY unset — explorer verification will be skipped (fine for a testnet rehearsal)."
  fi
fi

LATEST_FILE="$ROOT_DIR/deployments/deploy-${NETWORK_SLUG}-latest.json"

# --------------------------------------------------------------------------------------
# Preview: broadcast nothing. Show the handover plan if a prior deployment exists.
# --------------------------------------------------------------------------------------
if [[ "$EXECUTE" != true ]]; then
  echo
  echo "PREVIEW — nothing will be broadcast. On --execute this will:"
  echo "  1. ./bin/run-all.sh --broadcast            (deploy all contracts, owned by deployer)"
  echo "  2. ./bin/transfer-ownership-to-multisig.sh --execute --network=$NETWORK_SLUG"
  echo "  3. verify deployer owns nothing; timelocks + Safe own everything"
  if [[ -f "$LATEST_FILE" ]]; then
    echo
    echo "Existing deployment found — current ownership (dry-run handover plan):"
    SAFE_ADDRESS="$SAFE_ADDRESS" RPC_URL="$RPC_URL" OPS_DELAY="$OPS_DELAY" UPGRADE_DELAY="$UPGRADE_DELAY" \
      "$ROOT_DIR/bin/transfer-ownership-to-multisig.sh" --network="$NETWORK_SLUG" || true
  else
    echo
    echo "(no deployment summary at $LATEST_FILE yet — the deploy core will create it on --execute)"
  fi
  exit 0
fi

# --------------------------------------------------------------------------------------
# Execute: deploy -> handover -> verify.
# --------------------------------------------------------------------------------------
echo
echo ">>> [1/3] Deploying contracts (./bin/run-all.sh --broadcast) <<<"
"$ROOT_DIR/bin/run-all.sh" --broadcast

echo
echo ">>> [2/3] Governance handover (./bin/transfer-ownership-to-multisig.sh --execute) <<<"
HANDOVER_LOG="$(mktemp)"
trap 'rm -f "$HANDOVER_LOG"' EXIT
set +e
SAFE_ADDRESS="$SAFE_ADDRESS" RPC_URL="$RPC_URL" PRIVATE_KEY="$PRIVATE_KEY" \
  OPS_DELAY="$OPS_DELAY" UPGRADE_DELAY="$UPGRADE_DELAY" \
  "$ROOT_DIR/bin/transfer-ownership-to-multisig.sh" --execute --network="$NETWORK_SLUG" 2>&1 | tee "$HANDOVER_LOG"
HANDOVER_RC="${PIPESTATUS[0]}"
set -e
[[ "$HANDOVER_RC" -eq 0 ]] || die "handover script failed (rc=$HANDOVER_RC) — see output above"

OPS_TIMELOCK="$(grep -oE 'Ops TimeLock \(owner / 24h\): +0x[a-fA-F0-9]{40}' "$HANDOVER_LOG" | grep -oE '0x[a-fA-F0-9]{40}' | tail -1)"
UPGRADE_TIMELOCK="$(grep -oE 'Upgrade TimeLock \(admin / 48h\): +0x[a-fA-F0-9]{40}' "$HANDOVER_LOG" | grep -oE '0x[a-fA-F0-9]{40}' | tail -1)"
[[ -n "$OPS_TIMELOCK" && -n "$UPGRADE_TIMELOCK" ]] \
  || die "could not parse timelock addresses from handover output"

echo
echo ">>> [3/3] Verifying hardened state <<<"
[[ -f "$LATEST_FILE" ]] || die "deployment summary not found: $LATEST_FILE"

read_addr() {
  local key="$1" val
  val="$(jq -r --arg k "$key" '.[$k] // ""' "$LATEST_FILE")"
  [[ -n "$val" && "$val" != "null" && "$val" != "0x" ]] || die "summary missing '$key'"
  echo "$val"
}

# Same 11 proxies + 6 pausable set as transfer-ownership-to-multisig.sh — keep in lockstep.
NAMES=(BalanceLedger Centuari Settlement HubDepositor CollateralManager WithdrawalRegistry HubIntentSettler SettlementLedger RiskModule OracleRouter LiquidationEngine)
KEYS=(balanceLedgerAddress centuariAddress settlementProxy hubDepositorAddress collateralManagerAddress withdrawalRegistryAddress hubIntentSettlerAddress settlementLedgerAddress riskModuleAddress oracleRouterAddress liquidationEngineAddress)
PAUSABLE_NAMES=(BalanceLedger Centuari Settlement WithdrawalRegistry HubIntentSettler LiquidationEngine)

DEPLOYER_LC="$(printf '%s' "$DEPLOYER" | lc)"

FAILS=0
check() { # check <label> <actual> <expected>
  local actual_lc expected_lc; actual_lc="$(printf '%s' "$2" | lc)"; expected_lc="$(printf '%s' "$3" | lc)"
  if [[ "$actual_lc" == "$expected_lc" ]]; then
    printf '  OK   %-40s -> %s\n' "$1" "$2"
  else
    printf '  FAIL %-40s -> %s (expected %s)\n' "$1" "$2" "$3"; FAILS=$((FAILS+1))
  fi
}
no_deployer() { # no_deployer <label> <addr>
  if [[ "$(printf '%s' "$2" | lc)" == "$DEPLOYER_LC" ]]; then
    printf '  FAIL %-40s STILL owned by deployer EOA (%s)\n' "$1" "$2"; FAILS=$((FAILS+1))
  fi
}

for i in "${!KEYS[@]}"; do
  proxy="$(read_addr "${KEYS[$i]}")"
  name="${NAMES[$i]}"
  owner="$(cast call "$proxy" "owner()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "")"
  admin="$(cast parse-bytes32-address "$(cast storage "$proxy" "$ADMIN_SLOT" --rpc-url "$RPC_URL")" 2>/dev/null || echo "")"
  admin_owner="$(cast call "$admin" "owner()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "")"
  check "$name.owner()" "$owner" "$OPS_TIMELOCK"
  check "$name ProxyAdmin.owner()" "$admin_owner" "$UPGRADE_TIMELOCK"
  no_deployer "$name.owner()" "$owner"
  no_deployer "$name ProxyAdmin.owner()" "$admin_owner"
done

for name in "${PAUSABLE_NAMES[@]}"; do
  idx=-1; for j in "${!NAMES[@]}"; do [[ "${NAMES[$j]}" == "$name" ]] && idx="$j"; done
  proxy="$(read_addr "${KEYS[$idx]}")"
  pauser="$(cast call "$proxy" "pauser()(address)" --rpc-url "$RPC_URL" 2>/dev/null || echo "")"
  check "$name.pauser()" "$pauser" "$SAFE_ADDRESS"
done

# Audit M-1: BalanceLedger's collateral-flag writes (markCollateral/unmarkCollateral)
# share a single onlyAuthorizedWriter gate with credit/debit, so ANY authorized
# writer can flag/unflag arbitrary collateral. There is no on-chain enumeration, so
# assert (a) each intended contract IS a writer, (b) the deployer EOA is NOT, and
# (c) the testnet forceAddWriter fast path is permanently OFF on mainnet.
# (script/VerifyBalanceLedgerWriters.s.sol does the same for testnet / ad-hoc runs.)
BL_ADDR="$(read_addr balanceLedgerAddress)"
WRITER_NAMES=(Centuari Settlement HubDepositor CollateralManager WithdrawalRegistry HubIntentSettler LiquidationEngine)
WRITER_KEYS=(centuariAddress settlementProxy hubDepositorAddress collateralManagerAddress withdrawalRegistryAddress hubIntentSettlerAddress liquidationEngineAddress)
for i in "${!WRITER_KEYS[@]}"; do
  w="$(read_addr "${WRITER_KEYS[$i]}")"
  is_writer="$(cast call "$BL_ADDR" "isAuthorizedWriter(address)(bool)" "$w" --rpc-url "$RPC_URL" 2>/dev/null || echo "")"
  check "BalanceLedger writer ${WRITER_NAMES[$i]}" "$is_writer" "true"
done
dep_is_writer="$(cast call "$BL_ADDR" "isAuthorizedWriter(address)(bool)" "$DEPLOYER" --rpc-url "$RPC_URL" 2>/dev/null || echo "")"
check "BalanceLedger deployer NOT a writer" "$dep_is_writer" "false"
force_enabled="$(cast call "$BL_ADDR" "forceWriterRegistrationEnabled()(bool)" --rpc-url "$RPC_URL" 2>/dev/null || echo "")"
check "BalanceLedger forceWriterRegistration OFF" "$force_enabled" "false"

ops_delay_onchain="$(cast call "$OPS_TIMELOCK" "getMinDelay()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "")"
up_delay_onchain="$(cast call "$UPGRADE_TIMELOCK" "getMinDelay()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null || echo "")"
check "ops timelock getMinDelay()" "$ops_delay_onchain" "$OPS_DELAY"
check "upgrade timelock getMinDelay()" "$up_delay_onchain" "$UPGRADE_DELAY"

echo
if [[ "$FAILS" -eq 0 ]]; then
  echo "=== HARDENED ✅ — deployer EOA owns nothing; governance on Safe + timelocks ==="
  echo "Ops TimeLock (owner / setters): $OPS_TIMELOCK  (${OPS_DELAY}s)"
  echo "Upgrade TimeLock (upgrades):    $UPGRADE_TIMELOCK  (${UPGRADE_DELAY}s)"
  echo "Guardian (pause):               $SAFE_ADDRESS"
  echo "Deployer EOA ($DEPLOYER): powerless"
else
  die "$FAILS verification check(s) FAILED — deployment is NOT safely hardened. Investigate immediately."
fi
