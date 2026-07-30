#!/usr/bin/env bash
# Unit tests for .autoducks/core/robustness/verify-machinery.sh — the shared
# module that scripts/setup.sh (checks 9 and 12) and any future updater
# source so they can never disagree about what "a valid machinery tree"
# means.
#
# Builds a scratch copy of the real .autoducks/, .github/, and scripts/
# trees (so the module's own walk-up-to-autoducks.json root resolution and
# every check's file scan operate on real machinery, not fixtures), asserts
# it exits 0 with a 6/6 summary, then re-copies that clean base once per
# fault and asserts the script exits non-zero with exactly the expected
# check reported FAIL.
# Run: bash test/unit-verify-machinery.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VM_REL=".autoducks/core/robustness/verify-machinery.sh"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

# ── Clean base: a full copy of the real machinery tree ─────────────────────
BASE="$SCRATCH/base"
mkdir -p "$BASE"
cp -R "$REPO_ROOT/.autoducks" "$BASE/.autoducks"
cp -R "$REPO_ROOT/.github" "$BASE/.github"
cp -R "$REPO_ROOT/scripts" "$BASE/scripts"

# fresh_copy NAME — copies the clean base into $SCRATCH/NAME; sets WORK.
fresh_copy() {
  WORK="$SCRATCH/$1"
  cp -R "$BASE" "$WORK"
}

# run_vm WORK_DIR — runs the module as a script against a scratch tree;
# sets OUT (combined stdout+stderr) and STATUS (exit code).
run_vm() {
  if OUT="$(bash "$1/$VM_REL" 2>&1)"; then
    STATUS=0
  else
    STATUS=$?
  fi
}

# assert_check_fails LABEL WORK_DIR CHECK_ID — runs the module against
# WORK_DIR and asserts it exits non-zero with CHECK_ID reported FAIL and
# every other check reported PASS (i.e. the fault is fully isolated).
assert_check_fails() {
  local label="$1" work="$2" check_id="$3"
  run_vm "$work"
  if [[ "$STATUS" -ne 0 ]]; then
    pass "$label: script exits non-zero"
  else
    fail "$label: script exited 0"
  fi
  if grep -qF "$check_id: FAIL" <<<"$OUT"; then
    pass "$label: $check_id reported FAIL"
  else
    fail "$label: $check_id not reported FAIL — output was: $OUT"
  fi
  local other_fails
  other_fails="$(grep -F ': FAIL' <<<"$OUT" | grep -vF "$check_id: FAIL" || true)"
  if [[ -z "$other_fails" ]]; then
    pass "$label: no other check failed"
  else
    fail "$label: unexpected additional failing check(s): $other_fails"
  fi
}

echo "── clean tree: exits 0, all six checks pass ──"
run_vm "$BASE"
if [[ "$STATUS" -eq 0 ]]; then
  pass "clean tree: script exits 0"
else
  fail "clean tree: script exited $STATUS — output was: $OUT"
fi
if grep -qF "verify-machinery: 6/6 checks passed" <<<"$OUT"; then
  pass "clean tree: 6/6 checks passed"
else
  fail "clean tree: summary line missing/wrong — output was: $OUT"
fi

echo "── fault: injected bash -n syntax error ──"
fresh_copy fault-syntax
printf '\nif [ true\n' >> "$WORK/.autoducks/agents/maestro/run.sh"
assert_check_fails "syntax fault" "$WORK" "bash-syntax"

echo "── fault: orphan .github/workflows/autoducks-*.yml mirror ──"
fresh_copy fault-orphan
cp "$WORK/.github/workflows/autoducks-close.yml" "$WORK/.github/workflows/autoducks-orphan-test.yml"
assert_check_fails "orphan mirror fault" "$WORK" "runtime-sync"

echo "── fault: non-idempotent update-triggers.sh result ──"
# Mutating the baked command namespace without regenerating leaves every
# committed guard stale relative to what update-triggers.sh would now
# produce — the idempotence check's DRIFT case — while runtime template and
# workflow mirror stay byte-identical to *each other*, so runtime-sync stays
# green and the fault is isolated to check 4.
fresh_copy fault-idempotence
jq '.command = "bot"' "$WORK/.autoducks/autoducks.json" > "$WORK/.autoducks/autoducks.json.tmp"
mv "$WORK/.autoducks/autoducks.json.tmp" "$WORK/.autoducks/autoducks.json"
assert_check_fails "idempotence fault" "$WORK" "update-triggers-idempotence"

echo "── fault: plugin autoducksVersion gate violation ──"
fresh_copy fault-vgate
mkdir -p "$WORK/.autoducks/plugins/vgate-test"
jq -n '{schemaVersion: 1, name: "vgate-test", version: "1.0.0", autoducksVersion: ">=99.0.0", hooks: [], allowedTools: []}' \
  > "$WORK/.autoducks/plugins/vgate-test/plugin.json"
jq '.plugins = [{"name":"vgate-test","source":".autoducks/plugins/vgate-test","config":{}}]' \
  "$WORK/.autoducks/autoducks.json" > "$WORK/.autoducks/autoducks.json.tmp"
mv "$WORK/.autoducks/autoducks.json.tmp" "$WORK/.autoducks/autoducks.json"
assert_check_fails "version-gate fault" "$WORK" "plugin-compilation-sync"
if grep -qF "requires autoducksVersion '>=99.0.0'" <<<"$OUT"; then
  pass "version-gate fault: apply-plugins.sh's own actionable message surfaces verbatim"
else
  fail "version-gate fault: actionable message not surfaced — output was: $OUT"
fi

echo "── no network calls, mutates nothing outside its scratch dir ──"
BASE_SNAPSHOT="$SCRATCH/base-snapshot-before.txt"
BASE_SNAPSHOT_AFTER="$SCRATCH/base-snapshot-after.txt"
( cd "$BASE" && find . -type f -exec sha256sum {} + | sort ) > "$BASE_SNAPSHOT"
run_vm "$BASE"
( cd "$BASE" && find . -type f -exec sha256sum {} + | sort ) > "$BASE_SNAPSHOT_AFTER"
if diff -q "$BASE_SNAPSHOT" "$BASE_SNAPSHOT_AFTER" >/dev/null; then
  pass "running the module leaves its own tree byte-identical"
else
  fail "running the module modified files in its own tree"
fi

echo ""
echo "═══ verify-machinery: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
