#!/usr/bin/env bash
# Unit tests for .autoducks/core/orchestration/dispatch-chain.sh
# Run: bash test/unit-dispatch-chain.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

# Mock the git provider dispatch — record calls instead of hitting gh.
DISPATCH_LOG=$(mktemp)
git::dispatch_workflow() {
  echo "$*" >> "$DISPATCH_LOG"
}

# shellcheck source=/dev/null
source "$REPO_ROOT/.autoducks/core/orchestration/dispatch-chain.sh"

reset_log() { : > "$DISPATCH_LOG"; }
last_dispatch() { tail -1 "$DISPATCH_LOG"; }
dispatch_count() { wc -l < "$DISPATCH_LOG" | tr -d ' '; }

# ---------------------------------------------------------------------------
echo "── chain::dispatch_next ──"

reset_log
chain::dispatch_next "" "42"
[[ "$(dispatch_count)" == "0" ]] \
  && pass "empty chain dispatches nothing" \
  || fail "empty chain dispatched: $(last_dispatch)"

reset_log
chain::dispatch_next "engineer" "42"
[[ "$(last_dispatch)" == "autoducks-engineer.yml -f issue_number=42" ]] \
  && pass "single-verb chain dispatches engineer with no remainder" \
  || fail "got: $(last_dispatch)"

reset_log
chain::dispatch_next "engineer+execute" "42"
[[ "$(last_dispatch)" == "autoducks-engineer.yml -f issue_number=42 -f auto_chain=execute" ]] \
  && pass "multi-verb chain forwards the remainder" \
  || fail "got: $(last_dispatch)"

reset_log
chain::dispatch_next "execute" "42"
[[ "$(last_dispatch)" == "autoducks-maestro.yml -f feature_issue=42" ]] \
  && pass "chained execute targets the Maestro with feature_issue" \
  || fail "got: $(last_dispatch)"

reset_log
chain::dispatch_next "architect" "7"
[[ "$(last_dispatch)" == "autoducks-architect.yml -f issue_number=7" ]] \
  && pass "chained architect targets the Architect" \
  || fail "got: $(last_dispatch)"

reset_log
COMMENTER="alice" OVERRIDE_MODEL="claude-opus-4-8" OVERRIDE_EFFORT="high" OVERRIDE_MAX_TURNS="30" \
  chain::dispatch_next "engineer" "42"
[[ "$(last_dispatch)" == "autoducks-engineer.yml -f issue_number=42 -f actor=alice -f model=claude-opus-4-8 -f effort=high -f max_turns=30" ]] \
  && pass "actor/model/effort/turns overrides are forwarded" \
  || fail "got: $(last_dispatch)"

reset_log
chain::dispatch_next "banana" "42" 2>/dev/null || true
[[ "$(dispatch_count)" == "0" ]] \
  && pass "unknown verb is dropped without dispatch" \
  || fail "unknown verb dispatched: $(last_dispatch)"

echo "── chain::dispatch_prerequisite ──"

reset_log
chain::dispatch_prerequisite "architect" "engineer" "" "42"
[[ "$(last_dispatch)" == "autoducks-architect.yml -f issue_number=42 -f auto_chain=engineer" ]] \
  && pass "prerequisite re-queues the current agent" \
  || fail "got: $(last_dispatch)"

reset_log
chain::dispatch_prerequisite "engineer" "execute" "" "42"
[[ "$(last_dispatch)" == "autoducks-engineer.yml -f issue_number=42 -f auto_chain=execute" ]] \
  && pass "maestro DoR delegates to engineer with execute re-queued" \
  || fail "got: $(last_dispatch)"

reset_log
chain::dispatch_prerequisite "architect" "engineer" "execute" "42"
[[ "$(last_dispatch)" == "autoducks-architect.yml -f issue_number=42 -f auto_chain=engineer+execute" ]] \
  && pass "existing chain is preserved after the re-queued agent" \
  || fail "got: $(last_dispatch)"

reset_log
if chain::dispatch_prerequisite "architect" "architect" "" "42" 2>/dev/null; then
  fail "loop (prereq == current) was not refused"
else
  [[ "$(dispatch_count)" == "0" ]] \
    && pass "loop (prereq == current) refused without dispatch" \
    || fail "loop refused but still dispatched"
fi

reset_log
if chain::dispatch_prerequisite "engineer" "execute" "engineer+fix" "42" 2>/dev/null; then
  fail "loop (prereq already in chain) was not refused"
else
  pass "loop (prereq already in chain) refused"
fi

rm -f "$DISPATCH_LOG"

# ---------------------------------------------------------------------------
echo ""
echo "═══ dispatch-chain: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
