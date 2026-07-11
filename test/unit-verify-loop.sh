#!/usr/bin/env bash
# Unit tests for .autoducks/core/robustness/verify-loop.sh
# Run: bash test/unit-verify-loop.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE="$REPO_ROOT/.autoducks/core/robustness/verify-loop.sh"
PASS=0
FAIL=0

pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

SCRATCH=$(mktemp -d)
export SCRATCH
mkdir -p "$SCRATCH/repo"
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

export AUTODUCKS_REPO_ROOT="$SCRATCH/repo"
export AUTODUCKS_CONFIG="$SCRATCH/autoducks.json"
export AUTODUCKS_CHECK_OUTPUT_FILE="$SCRATCH/check-output.md"

# write_commands JSON — sets .checks.commands in the scratch config
write_commands() {
  jq -n --argjson commands "$1" '{checks: {commands: $commands}}' > "$AUTODUCKS_CONFIG"
}

reset_env() {
  write_commands "$1"
  unset AUTODUCKS_CHECKS_SETUP || true
  export AUTODUCKS_CHECKS_ENABLED="${2:-true}"
  export AUTODUCKS_CHECKS_GIT_HOOKS="${3:-false}"
  unset AUTODUCKS_CHECKS_OUTPUT_BYTES || true
  rm -f "$AUTODUCKS_CHECK_OUTPUT_FILE"
}

source "$MODULE"

# ---------------------------------------------------------------------------
# Test 1: all commands pass → exit 0
# ---------------------------------------------------------------------------
echo "[1] all-pass → exit 0"
reset_env '[{"name":"lint","run":"true"},{"name":"build","run":"true"}]'
rc=0
verify_loop::run_checks || rc=$?
if [[ "$rc" -eq 0 ]]; then
  pass "returns 0 when every check passes"
else
  fail "expected exit 0, got $rc"
fi

# ---------------------------------------------------------------------------
# Test 2: first-failure fail-fast → exit 1, later commands don't run
# ---------------------------------------------------------------------------
echo "[2] fail-fast on first failure"
rm -f "$SCRATCH/marker_b_ran"
reset_env '[{"name":"a","run":"exit 1"},{"name":"b","run":"touch \"$SCRATCH/marker_b_ran\""}]'
rc=0
verify_loop::run_checks || rc=$?
if [[ "$rc" -eq 1 ]]; then
  pass "returns 1 on a failing check"
else
  fail "expected exit 1, got $rc"
fi
if [[ ! -e "$SCRATCH/marker_b_ran" ]]; then
  pass "later command never ran"
else
  fail "second command ran despite the first one failing"
fi
if [[ -f "$AUTODUCKS_CHECK_OUTPUT_FILE" ]] && grep -q '`a`' "$AUTODUCKS_CHECK_OUTPUT_FILE"; then
  pass "output file names the failing check"
else
  fail "output file missing or doesn't name the failing check"
fi

# ---------------------------------------------------------------------------
# Test 3: setup failure → exit 2 (infra), no commands run
# ---------------------------------------------------------------------------
echo "[3] setup failure → exit 2"
rm -f "$SCRATCH/marker_c_ran"
reset_env '[{"name":"c","run":"touch \"$SCRATCH/marker_c_ran\""}]'
export AUTODUCKS_CHECKS_SETUP="exit 3"
rc=0
verify_loop::run_checks || rc=$?
unset AUTODUCKS_CHECKS_SETUP
if [[ "$rc" -eq 2 ]]; then
  pass "returns 2 when setup fails"
else
  fail "expected exit 2, got $rc"
fi
if [[ ! -e "$SCRATCH/marker_c_ran" ]]; then
  pass "no check command ran after setup failed"
else
  fail "a check command ran despite setup failing"
fi

# ---------------------------------------------------------------------------
# Test 4: enabled — disabled flag / no commands / commands present / git_hooks
# ---------------------------------------------------------------------------
echo "[4] verify_loop::enabled gating"
reset_env '[{"name":"lint","run":"true"}]' "false" "false"
rc=0
verify_loop::enabled || rc=$?
if [[ "$rc" -eq 1 ]]; then
  pass "disabled (AUTODUCKS_CHECKS_ENABLED=false) → not enabled"
else
  fail "expected not-enabled, got rc=$rc"
fi

reset_env '[]' "true" "false"
rc=0
verify_loop::enabled || rc=$?
if [[ "$rc" -eq 1 ]]; then
  pass "enabled but no commands/git_hooks → not enabled"
else
  fail "expected not-enabled, got rc=$rc"
fi

reset_env '[{"name":"lint","run":"true"}]' "true" "false"
rc=0
verify_loop::enabled || rc=$?
if [[ "$rc" -eq 0 ]]; then
  pass "enabled with at least one command → enabled"
else
  fail "expected enabled, got rc=$rc"
fi

reset_env '[]' "true" "true"
rc=0
verify_loop::enabled || rc=$?
if [[ "$rc" -eq 0 ]]; then
  pass "enabled with git_hooks and no commands → enabled"
else
  fail "expected enabled, got rc=$rc"
fi

# ---------------------------------------------------------------------------
# Test 5: oversized output is truncated with a visible marker, under the cap
# ---------------------------------------------------------------------------
echo "[5] output truncation"
reset_env '[{"name":"bigfail","run":"yes X | head -c 5000; exit 1"}]'
export AUTODUCKS_CHECKS_OUTPUT_BYTES=200
rc=0
verify_loop::run_checks >/dev/null || rc=$?
unset AUTODUCKS_CHECKS_OUTPUT_BYTES
if [[ "$rc" -eq 1 ]]; then
  pass "big failing check still reports exit 1"
else
  fail "expected exit 1, got $rc"
fi
if grep -q '… truncated …' "$AUTODUCKS_CHECK_OUTPUT_FILE"; then
  pass "truncation notice present"
else
  fail "no truncation notice in output file"
fi
out_size=$(wc -c < "$AUTODUCKS_CHECK_OUTPUT_FILE" | tr -d ' ')
if [[ "$out_size" -lt 1000 ]]; then
  pass "output file size ($out_size bytes) stays well under the original 5000-byte log"
else
  fail "output file size ($out_size bytes) was not truncated"
fi

# ---------------------------------------------------------------------------
# Test 6: git_hooks with no discoverable hook config → no-op + ::warning::
# ---------------------------------------------------------------------------
echo "[6] git_hooks no-op path"
reset_env '[]' "true" "true"
rc=0
warn_out=$(verify_loop::run_checks 2>&1) || rc=$?
if [[ "$rc" -eq 0 ]]; then
  pass "git_hooks with nothing discoverable still exits 0"
else
  fail "expected exit 0, got $rc"
fi
if echo "$warn_out" | grep -q '::warning::'; then
  pass "emits ::warning:: when no hook config is found"
else
  fail "missing ::warning:: for undiscoverable git_hooks config"
fi

# ---------------------------------------------------------------------------
# Test 7: module never invokes git/gh write commands
# ---------------------------------------------------------------------------
echo "[7] no git/gh write commands in the module"
bad_git=$(grep -oE '\bgit [a-z][a-z-]*' "$MODULE" | sort -u | grep -v '^git rev-parse$' || true)
if [[ -z "$bad_git" ]]; then
  pass "only read-only 'git rev-parse' is invoked"
else
  fail "unexpected git subcommands: $bad_git"
fi
if grep -qE '\bgh (issue|pr|api|repo)\b' "$MODULE"; then
  fail "module invokes gh"
else
  pass "module never invokes gh"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "── config file tracks load-config's source of truth (#989) ──"
(
  unset AUTODUCKS_CONFIG
  export AUTODUCKS_ROOT="$SCRATCH/pinned"
  source "$MODULE"
  [[ "$(_verify_loop::config_file)" == "$SCRATCH/pinned/autoducks.json" ]]
) && pass "config_file defaults to \$AUTODUCKS_ROOT/autoducks.json (matches load-config)" \
  || fail "config_file did not align with AUTODUCKS_ROOT"
(
  export AUTODUCKS_CONFIG="$SCRATCH/override.json"
  source "$MODULE"
  [[ "$(_verify_loop::config_file)" == "$SCRATCH/override.json" ]]
) && pass "config_file still honours an explicit AUTODUCKS_CONFIG override" \
  || fail "AUTODUCKS_CONFIG override not honoured"

echo "=== Unit Test Summary ==="
echo "  Pass: $PASS"
echo "  Fail: $FAIL"
if [[ "$FAIL" -eq 0 ]]; then
  echo "✅ All tests passed."
  exit 0
else
  echo "❌ $FAIL test(s) failed."
  exit 1
fi
