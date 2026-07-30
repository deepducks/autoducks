#!/usr/bin/env bash
# Unit tests for .autoducks/core/config/semver.sh
# Run: bash test/unit-semver.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SEMVER="$REPO_ROOT/.autoducks/core/config/semver.sh"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

echo "── static checks ──"
bash -n "$SEMVER" && pass "bash -n" || fail "bash -n failed"
if command -v shellcheck &>/dev/null; then
  shellcheck "$SEMVER" && pass "shellcheck" || fail "shellcheck failed"
else
  echo "  (shellcheck not installed, skipping)"
fi

echo "── sourceable twice ──"
(
  # shellcheck source=/dev/null
  source "$SEMVER"
  # shellcheck source=/dev/null
  source "$SEMVER"
) && pass "double source is a no-op" || fail "double source errored"

# shellcheck source=/dev/null
source "$SEMVER"

echo "── semver::num ──"
[[ "$(semver::num "0.4.2")" == "000000000400002" ]] \
  && pass "semver::num fixed-width form" || fail "semver::num mismatch: $(semver::num "0.4.2")"
[[ "$(semver::num "1.2.3")" == "000010000200003" ]] \
  && pass "semver::num 1.2.3" || fail "semver::num 1.2.3 mismatch: $(semver::num "1.2.3")"
[[ "$(semver::num "10.20.30")" == "$(printf '%05d%05d%05d' 10 20 30)" ]] \
  && pass "semver::num multi-digit components" || fail "semver::num multi-digit mismatch: $(semver::num "10.20.30")"

echo "── semver::compare ──"
[[ "$(semver::compare "1.2.3" "1.2.3")" == "0" ]] && pass "compare equal" || fail "compare equal wrong"
[[ "$(semver::compare "1.2.3" "1.3.0")" == "-1" ]] && pass "compare less-than" || fail "compare less-than wrong"
[[ "$(semver::compare "2.0.0" "1.9.9")" == "1" ]] && pass "compare greater-than" || fail "compare greater-than wrong"

echo "── semver::satisfies grammar (>=|<=|>|<|=) ──"
check_satisfies() { # host constraint expected_status label
  local host="$1" constraint="$2" expected="$3" label="$4" status
  semver::satisfies "$host" "$constraint" && status=0 || status=$?
  [[ "$status" -eq "$expected" ]] && pass "$label" || fail "$label (expected status $expected, got $status)"
}
check_satisfies "1.2.3" ">=1.0.0" 0 ">= accepts host above"
check_satisfies "1.2.3" ">=1.2.3" 0 ">= accepts host equal"
check_satisfies "1.2.3" ">=2.0.0" 1 ">= rejects host below"
check_satisfies "1.2.3" "<=2.0.0" 0 "<= accepts host below"
check_satisfies "1.2.3" "<=1.2.3" 0 "<= accepts host equal"
check_satisfies "1.2.3" "<=1.0.0" 1 "<= rejects host above"
check_satisfies "1.2.3" ">1.0.0" 0 "> accepts strictly-greater host"
check_satisfies "1.2.3" ">1.2.3" 1 "> rejects host equal (strict)"
check_satisfies "1.2.3" "<2.0.0" 0 "< accepts strictly-lesser host"
check_satisfies "1.2.3" "<1.2.3" 1 "< rejects host equal (strict)"
check_satisfies "1.2.3" "=1.2.3" 0 "= accepts host equal"
check_satisfies "1.2.3" "=1.2.4" 1 "= rejects host unequal"
check_satisfies "1.2.3" "1.2.3" 0 "no-operator constraint defaults to ="
check_satisfies "1.2.3" "1.2.4" 1 "no-operator constraint rejects unequal host"
check_satisfies "1.2.3" "bogus" 2 "malformed constraint (non-numeric)"
check_satisfies "1.2.3" ">=1.0" 2 "malformed constraint (missing patch component)"
check_satisfies "1.2.3" "~1.0.0" 2 "malformed constraint (unsupported operator)"

echo "── semver::bump_kind ──"
[[ "$(semver::bump_kind "1.2.3" "1.2.3")" == "none" ]] && pass "bump_kind none" || fail "bump_kind none wrong"
[[ "$(semver::bump_kind "1.2.3" "1.2.4")" == "patch" ]] && pass "bump_kind patch" || fail "bump_kind patch wrong"
[[ "$(semver::bump_kind "1.2.3" "1.3.0")" == "minor" ]] && pass "bump_kind minor" || fail "bump_kind minor wrong"
[[ "$(semver::bump_kind "1.2.3" "2.0.0")" == "major" ]] && pass "bump_kind major" || fail "bump_kind major wrong"
[[ "$(semver::bump_kind "1.2.3" "1.2.2")" == "downgrade" ]] && pass "bump_kind downgrade (patch)" || fail "bump_kind downgrade (patch) wrong"
[[ "$(semver::bump_kind "2.0.0" "1.9.9")" == "downgrade" ]] && pass "bump_kind downgrade (major)" || fail "bump_kind downgrade (major) wrong"

echo ""
echo "═══ semver: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
