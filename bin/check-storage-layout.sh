#!/usr/bin/env bash
#
# check-storage-layout.sh — guard against accidental storage-layout breaks in
# upgradeable contracts (see CLAUDE.md "Upgrade Safety").
#
# For each upgradeable contract it runs `forge inspect <C> storage-layout --json`
# and compares the result against the committed snapshot in test/snapshots/<C>.storage.json.
# Any change to a variable's label/slot/offset/type — or the resolved `types` map
# (gap size, struct member layout, ...) — fails the check with a unified diff.
#
#   bin/check-storage-layout.sh            # check; non-zero exit on drift (CI gate)
#   bin/check-storage-layout.sh --update   # (re)generate snapshots after an intentional change
#   bin/check-storage-layout.sh --help
#
# Why the normalizer strips astIds: solc/forge embed AST node ids in the layout —
# the top-level `astId` field, struct member `astId`s, and the numbers baked into
# type identifiers (`t_struct(Balance)8084_storage`, `t_enum(...)N`, `t_contract(...)N`).
# These ids shift whenever *any* source compiled before the contract changes, even
# when the layout is byte-identical, so comparing them raw makes the guard cry wolf.
# Array lengths look similar (`t_array(t_uint256)42_storage`) but are real layout and
# are preserved — hence the kind-specific stripping below.
#
# Gotcha (found in C6 Phase 3): a prior plain `forge build` can cache artifacts
# WITHOUT the storageLayout output selection, after which `forge inspect` returns
# "Could not get storage layout". We `forge clean` once up front to force a fresh
# compile that includes it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
SNAPSHOT_DIR="$ROOT_DIR/test/snapshots"

# Upgradeable contracts under storage-layout protection. Snapshot file is
# test/snapshots/<name>.storage.json; the name is also the `forge inspect` target.
CONTRACTS=(
  BalanceLedger
  Centuari
  CollateralManager
  Settlement
  HubDepositor
  WithdrawalRegistry
  HubIntentSettler
  SettlementLedger
  RiskModule
  OracleRouter
  LiquidationEngine
)

MODE="check"
case "${1:-}" in
  -u | --update) MODE="update" ;;
  -h | --help)
    grep '^#' "${BASH_SOURCE[0]}" | sed -e 's/^# \{0,1\}//' -e '1d'
    exit 0
    ;;
  "") ;;
  *)
    echo "unknown argument: $1 (try --help)" >&2
    exit 2
    ;;
esac

command -v forge >/dev/null 2>&1 || { echo "error: forge not found on PATH" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "error: jq not found on PATH" >&2; exit 2; }

# jq filter: drop volatile astIds (top-level + struct members + embedded in type
# identifiers) and canonicalize ordering so the diff reflects only real layout.
read -r -d '' NORMALIZE_JQ <<'JQ' || true
def norm_typename:
  gsub("(?<p>t_struct\\([^)]*\\))[0-9]+_storage"; "\(.p)_storage")
  | gsub("(?<p>t_enum\\([^)]*\\))[0-9]+"; "\(.p)")
  | gsub("(?<p>t_contract\\([^)]*\\))[0-9]+"; "\(.p)")
  | gsub("(?<p>t_userDefinedValueType\\([^)]*\\))[0-9]+"; "\(.p)");

def scrub:
  walk(
    if type == "object" then (del(.astId) | del(.contract))
    elif type == "string" then norm_typename
    else . end
  );

scrub
| .storage = ((.storage // []) | sort_by((.slot | tonumber), .offset))
| .types = ((.types // {}) | with_entries(.key |= norm_typename))
| { storage, types }
JQ

inspect_layout() {
  # Emits raw `forge inspect` JSON for a contract, or fails loudly.
  local contract="$1" out
  if ! out="$(TZ=UTC forge inspect "$contract" storage-layout --json 2>/dev/null)"; then
    echo "error: 'forge inspect $contract storage-layout' failed" >&2
    return 1
  fi
  if ! printf '%s' "$out" | jq -e 'has("storage")' >/dev/null 2>&1; then
    echo "error: no storage layout returned for $contract (stale artifacts? try 'forge clean')" >&2
    return 1
  fi
  printf '%s\n' "$out"
}

echo ">> forge clean (force fresh storageLayout output selection)"
TZ=UTC forge clean >/dev/null

failures=0

if [ "$MODE" = "update" ]; then
  mkdir -p "$SNAPSHOT_DIR"
  for c in "${CONTRACTS[@]}"; do
    if raw="$(inspect_layout "$c")"; then
      printf '%s\n' "$raw" | jq . >"$SNAPSHOT_DIR/$c.storage.json"
      echo "  updated test/snapshots/$c.storage.json"
    else
      failures=$((failures + 1))
    fi
  done
  [ "$failures" -eq 0 ] && echo "snapshots up to date." || echo "$failures contract(s) failed to inspect." >&2
  exit "$([ "$failures" -eq 0 ] && echo 0 || echo 1)"
fi

# check mode
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for c in "${CONTRACTS[@]}"; do
  snapshot="$SNAPSHOT_DIR/$c.storage.json"
  if [ ! -f "$snapshot" ]; then
    echo "FAIL  $c — no committed snapshot (run: bin/check-storage-layout.sh --update)" >&2
    failures=$((failures + 1))
    continue
  fi

  raw="$(inspect_layout "$c")" || { failures=$((failures + 1)); continue; }

  jq -S "$NORMALIZE_JQ" "$snapshot" >"$tmp/$c.committed.json"
  printf '%s\n' "$raw" | jq -S "$NORMALIZE_JQ" >"$tmp/$c.current.json"

  if diff -u \
      --label "test/snapshots/$c.storage.json (committed)" \
      --label "$c storage-layout (current)" \
      "$tmp/$c.committed.json" "$tmp/$c.current.json"; then
    echo "ok    $c"
  else
    echo "FAIL  $c — storage layout drifted from committed snapshot" >&2
    failures=$((failures + 1))
  fi
done

echo
if [ "$failures" -ne 0 ]; then
  echo "storage-layout check FAILED for $failures contract(s)." >&2
  echo "If the change is intentional and upgrade-safe, regenerate with:" >&2
  echo "  bin/check-storage-layout.sh --update" >&2
  exit 1
fi
echo "storage-layout check passed for ${#CONTRACTS[@]} contracts."
