#!/usr/bin/env bash
# Unit tests for .autoducks/core/config/classify-label.sh
# Run: bash test/unit-classify-label.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

REPO="x/y"

# File-based log (not a shell variable): classify_label::ensure now routes
# through label::ensure, which invokes `gh` from inside command/process
# substitution subshells — a variable mutated by the stub there would be
# lost when the subshell exits, so the log has to be a file.
CALL_LOG_FILE="$(mktemp)"
trap 'rm -f "$CALL_LOG_FILE"' EXIT
log_call() { echo "$*" >> "$CALL_LOG_FILE"; }
reset_log() { : > "$CALL_LOG_FILE"; }

# Stubs for the caller-provided dependencies (gh, its::add_label,
# its::remove_label) so classify-label.sh can be exercised with no network.
gh() { log_call "gh $*"; return 0; }
its::add_label() { log_call "its::add_label $*"; return 0; }
its::remove_label() { log_call "its::remove_label $*"; return 0; }

# shellcheck source=/dev/null
source "$REPO_ROOT/.autoducks/core/config/classify-label.sh"

echo "── classify_label::color ──"
[[ "$(classify_label::color Bug)" == "D73A4A" ]] \
  && pass "Bug color is D73A4A" || fail "Bug color mismatch: $(classify_label::color Bug)"
[[ "$(classify_label::color Feature)" == "A2EEEF" ]] \
  && pass "Feature color is A2EEEF" || fail "Feature color mismatch: $(classify_label::color Feature)"

echo "── classify_label::apply Bug ──"
reset_log
classify_label::apply 42 Bug
grep -q 'gh label create Bug --repo x/y --color D73A4A' "$CALL_LOG_FILE" \
  && pass "Bug label created with canonical color" || fail "Bug label not created: $(cat "$CALL_LOG_FILE")"
grep -q 'its::add_label 42 Bug' "$CALL_LOG_FILE" \
  && pass "Bug label added to issue" || fail "Bug label not added: $(cat "$CALL_LOG_FILE")"
grep -q 'its::remove_label 42 Feature' "$CALL_LOG_FILE" \
  && pass "opposite Feature label removed" || fail "Feature label not removed: $(cat "$CALL_LOG_FILE")"

echo "── classify_label::apply Feature ──"
reset_log
classify_label::apply 42 Feature
grep -q 'gh label create Feature --repo x/y --color A2EEEF' "$CALL_LOG_FILE" \
  && pass "Feature label created with canonical color" || fail "Feature label not created: $(cat "$CALL_LOG_FILE")"
grep -q 'its::add_label 42 Feature' "$CALL_LOG_FILE" \
  && pass "Feature label added to issue" || fail "Feature label not added: $(cat "$CALL_LOG_FILE")"
grep -q 'its::remove_label 42 Bug' "$CALL_LOG_FILE" \
  && pass "opposite Bug label removed" || fail "Bug label not removed: $(cat "$CALL_LOG_FILE")"

echo "── classify_label::apply tolerates a missing opposite ──"
its::remove_label() { log_call "its::remove_label $*"; return 1; }
reset_log
RC=0
classify_label::apply 42 Bug || RC=$?
[[ "$RC" -eq 0 ]] && pass "apply still exits 0 when remove fails" || fail "apply propagated remove failure: rc=$RC"

echo ""
echo "═══ classify-label: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
