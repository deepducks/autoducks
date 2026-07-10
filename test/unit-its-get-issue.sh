#!/usr/bin/env bash
# Provider-contract test for .autoducks/providers/its/github/get-issue.sh
#
# its::get_issue is declared in .autoducks/providers/its/interface.sh:27 to
# return JSON {title, body, labels, type, author}. This test stubs `gh`
# (both the `gh issue view` and `gh api …/issues/<id>` calls its::get_issue
# makes) and asserts every declared key survives — so a dropped field (like
# the `type` regression this test was added to catch) fails CI instead of
# only surfacing at runtime.
#
# Run: bash test/unit-its-get-issue.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

# ── gh stub ──────────────────────────────────────────────────────────────
# its::get_issue shells out to `gh issue view ... --jq '...'` and
# `gh api repos/$REPO/issues/$id --jq '...'`. Since the real `gh` applies the
# --jq filter itself, this stub returns the ALREADY-FILTERED output each real
# call would have produced, keyed off MOCK_VIEW_JSON / MOCK_TYPE_OUT.
gh() {
  case "$1 $2" in
    "issue view")
      echo "$MOCK_VIEW_JSON"
      ;;
    "api "*)
      if [[ "${MOCK_API_FAIL:-false}" == "true" ]]; then
        return 1
      fi
      echo "$MOCK_TYPE_OUT"
      ;;
    *)
      echo "gh stub: unexpected invocation: $*" >&2
      return 1
      ;;
  esac
}

export REPO="acme/widgets"

# shellcheck source=/dev/null
source "$REPO_ROOT/.autoducks/providers/its/github/get-issue.sh"

echo "── its::get_issue: interface contract ──"

MOCK_VIEW_JSON='{"title":"Login crash","body":"Steps to repro...","labels":["Bug","P1"],"author":"alice"}'
MOCK_TYPE_OUT="Bug"
MOCK_API_FAIL=false
OUT="$(its::get_issue 42)"

for key in title body labels type author; do
  if echo "$OUT" | jq -e "has(\"$key\")" >/dev/null 2>&1; then
    pass "output has key '$key'"
  else
    fail "output MISSING key '$key': $OUT"
  fi
done

[[ "$(echo "$OUT" | jq -r '.type')" == "Bug" ]] \
  && pass "type carries the native issue type" \
  || fail "type mismatch: $(echo "$OUT" | jq -r '.type')"
[[ "$(echo "$OUT" | jq -r '.title')" == "Login crash" ]] \
  && pass "title unchanged" || fail "title mismatch"
[[ "$(echo "$OUT" | jq -c '.labels')" == '["Bug","P1"]' ]] \
  && pass "labels still a string array" || fail "labels shape changed: $(echo "$OUT" | jq -c '.labels')"
[[ "$(echo "$OUT" | jq -r '.author')" == "alice" ]] \
  && pass "author still a login string" || fail "author shape changed"

echo ""
echo "── its::get_issue: degraded — no native type available ──"

MOCK_VIEW_JSON='{"title":"Add dark mode","body":"...","labels":["Feature"],"author":"bob"}'
MOCK_TYPE_OUT=""
MOCK_API_FAIL=false
RC=0
OUT="$(its::get_issue 7)" || RC=$?

[[ "$RC" -eq 0 ]] && pass "exits 0 when repo has no native types" || fail "expected exit 0, got rc=$RC"
[[ "$(echo "$OUT" | jq -r '.type')" == "null" ]] \
  && pass "type is null when lookup returns empty" || fail "type not null: $(echo "$OUT" | jq -c '.type')"

echo ""
echo "── its::get_issue: degraded — type lookup call fails outright ──"

MOCK_VIEW_JSON='{"title":"Flaky test","body":"...","labels":[],"author":"carol"}'
MOCK_TYPE_OUT=""
MOCK_API_FAIL=true
RC=0
OUT="$(its::get_issue 8)" || RC=$?

[[ "$RC" -eq 0 ]] && pass "exits 0 when the gh api call itself fails" || fail "expected exit 0, got rc=$RC"
[[ "$(echo "$OUT" | jq -r '.type')" == "null" ]] \
  && pass "type is null when the gh api call errors" || fail "type not null: $(echo "$OUT" | jq -c '.type')"
for key in title body labels type author; do
  if echo "$OUT" | jq -e "has(\"$key\")" >/dev/null 2>&1; then
    pass "degraded output still has key '$key'"
  else
    fail "degraded output MISSING key '$key': $OUT"
  fi
done

echo ""
echo "═══ its-get-issue: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
