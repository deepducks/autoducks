#!/usr/bin/env bash
# Unit tests for .autoducks/core/orchestration/orchestrator-mode.sh
#
# its::get_issue (.autoducks/providers/its/github/get-issue.sh:7) returns
# `labels` as a plain string array (`[.labels[].name]`), not an array of
# {name: ...} objects. orchestrator_mode::resolve's tier #2 (persisted label)
# must read labels the same way, or `jq` aborts on every issue that has any
# labels, the error is swallowed, and a persisted Mode:* override silently
# reverts to the config default on every merge-driven re-run.
#
# Run: bash test/unit-orchestrator-mode.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

# ── its::get_issue stub ─────────────────────────────────────────────────
# Returns the provider-contract shape: labels is an array of plain strings.
its::get_issue() {
  echo "{\"labels\":$MOCK_LABELS_JSON}"
}

# shellcheck source=/dev/null
source "$REPO_ROOT/.autoducks/core/orchestration/orchestrator-mode.sh"

echo "── orchestrator_mode::resolve: tier #2 — persisted Mode:* label ──"

unset OVERRIDE_MODE AUTODUCKS_ORCHESTRATOR_MODE 2>/dev/null || true

MOCK_LABELS_JSON='["Mode:sequential"]'
OUT="$(orchestrator_mode::resolve 123)"
[[ "$OUT" == "sequential" ]] \
  && pass "Mode:sequential label resolves to sequential" \
  || fail "expected 'sequential', got '$OUT'"

MOCK_LABELS_JSON='["Mode:waves"]'
OUT="$(orchestrator_mode::resolve 123)"
[[ "$OUT" == "waves" ]] \
  && pass "Mode:waves label resolves to waves" \
  || fail "expected 'waves', got '$OUT'"

MOCK_LABELS_JSON='["Mode:sequential","Priority:P1"]'
OUT="$(orchestrator_mode::resolve 123)"
[[ "$OUT" == "sequential" ]] \
  && pass "Mode:sequential resolves alongside unrelated labels" \
  || fail "expected 'sequential', got '$OUT'"

echo ""
echo "── orchestrator_mode::resolve: tier #3 — config default fallback ──"

MOCK_LABELS_JSON='["Priority:P1","Bug"]'
OUT="$(orchestrator_mode::resolve 123)"
[[ "$OUT" == "waves" ]] \
  && pass "no Mode:* label falls through to default 'waves'" \
  || fail "expected 'waves', got '$OUT'"

MOCK_LABELS_JSON='[]'
AUTODUCKS_ORCHESTRATOR_MODE="sequential"
OUT="$(orchestrator_mode::resolve 123)"
unset AUTODUCKS_ORCHESTRATOR_MODE
[[ "$OUT" == "sequential" ]] \
  && pass "no Mode:* label falls through to configured AUTODUCKS_ORCHESTRATOR_MODE" \
  || fail "expected 'sequential', got '$OUT'"

echo ""
echo "═══ orchestrator-mode: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
