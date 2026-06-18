#!/usr/bin/env bash
# check-effects-version.sh
#
# Guards the @centuari-labs/on-chain-effects invariant.
#
# After Track C7, the stamped on-chain-state mutation SQL lives in exactly one
# place — on-chain-effects/src/mutations.ts — and is imported by every writer
# (backend-v2, settlement-engine, indexer-v3, and sweeper-bot later). Because the
# services install STANDALONE (no pnpm workspace), they can silently drift on the
# *version* of that package, which re-diverges the SQL and breaks C10 replay
# idempotency. This script fails loudly when a consumer would resolve to a
# different minor version than the on-disk source of truth.
#
# Exit: 0 = OK, 1 = drift found, 2 = setup error.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 2
command -v jq >/dev/null 2>&1 || { echo "check-effects-version: jq is required" >&2; exit 2; }

SRC_PKG="on-chain-effects/package.json"
[ -f "$SRC_PKG" ] || { echo "check-effects-version: $SRC_PKG not found" >&2; exit 2; }

CONSUMERS="backend-v2 settlement-engine indexer-v3"
[ -d sweeper-bot ] && CONSUMERS="$CONSUMERS sweeper-bot"

# major.minor of a version-ish string ("^0.4.0" / "file:.." handled by caller -> "0.4")
mm() { printf '%s' "$1" | sed -E 's/^[^0-9]*//; s/^([0-9]+\.[0-9]+).*/\1/'; }

fail=0
SRC_VERSION="$(jq -r '.version // "?"' "$SRC_PKG" 2>/dev/null)"
SRC_MM="$(mm "$SRC_VERSION")"
echo "on-chain-effects (source of truth): v$SRC_VERSION  [minor line $SRC_MM.x]"
echo ""
echo "Consumer declarations of @centuari-labs/on-chain-effects:"

have_file=0
have_registry=0
for c in $CONSUMERS; do
  pkg="$c/package.json"
  decl="$(jq -r '(.dependencies["@centuari-labs/on-chain-effects"]) // (.devDependencies["@centuari-labs/on-chain-effects"]) // "MISSING"' "$pkg" 2>/dev/null)"
  printf "  %-18s %s\n" "$c" "$decl"
  case "$decl" in
    MISSING)
      echo "      ✗ does not declare the shared package"
      fail=1
      ;;
    file:*)
      # local link always resolves to the on-disk source version
      have_file=1
      ;;
    *)
      have_registry=1
      emm="$(mm "$decl")"
      if [ -n "$emm" ] && [ "$emm" != "$SRC_MM" ]; then
        echo "      ✗ resolves to v$emm.x but source is v$SRC_MM.x — SQL would diverge"
        fail=1
      fi
      ;;
  esac
done
echo ""

# Declaration-style asymmetry is a real drift VECTOR even when versions line up
# today: file:-linked services track on-disk source instantly, registry-pinned
# services only move on republish + reinstall. Warn (don't fail) — the setup may
# be intentional for Docker builds, but the lockstep discipline must be honored.
if [ "$have_file" = 1 ] && [ "$have_registry" = 1 ]; then
  echo "⚠ WARNING: consumers mix local 'file:' links and registry ranges."
  echo "  When you bump on-chain-effects, republish it AND bump the registry-pinned"
  echo "  consumer(s) in the same change, or the stamped SQL silently diverges."
  echo ""
fi

# Advisory: surface raw DML on stamped tables outside the shared package. This is
# a heuristic (in_orders bookkeeping writes are legitimately raw), so it reports
# for human review and never fails the gate.
echo "Advisory — raw INSERT/UPDATE on stamped tables outside on-chain-effects/ (verify each routes through the shared helper):"
# Right boundary ([^a-zA-Z0-9_]|EOL) keeps singular stamped tables from matching the
# retired plural tables (markets / lend_positions / borrow_positions). Seeds/tests excluded.
hits="$(grep -rInE "(INSERT INTO|UPDATE)[[:space:]]+\"?(user_balance|lend_position|borrow_position|market)\"?([^a-zA-Z0-9_]|$)" \
        backend-v2/src settlement-engine/src indexer-v3/src 2>/dev/null \
        | grep -viE "(__test__|__tests__|\.test\.|\.spec\.|stub|migration|/seeds/)" || true)"
if [ -n "$hits" ]; then
  printf '%s\n' "$hits" | sed 's/^/    /'
  echo "  (review only — stamped writes with applied_by_* must use @centuari-labs/on-chain-effects)"
else
  echo "    ✓ none found"
fi
echo ""

if [ "$fail" = 0 ]; then
  echo "RESULT: PASS — on-chain-effects version invariant intact."
else
  echo "RESULT: FAIL — align consumers; drift breaks C10 replay idempotency."
fi
exit "$fail"
