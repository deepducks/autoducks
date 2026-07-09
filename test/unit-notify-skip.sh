#!/usr/bin/env bash
# Unit tests for .autoducks/core/feedback/notify-skip.sh
# Run: bash test/unit-notify-skip.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

export REPO="acme/widgets"
export AUTODUCKS_COMMAND="${AUTODUCKS_COMMAND:-}"

# Scratch directory cleaned up on exit.
SCRATCH=$(mktemp -d)
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# its::comment_issue stub — records each call to its own pair of files
# (counter file on disk so it works across the subshells tests fork into).
# ---------------------------------------------------------------------------
: > "$SCRATCH/counter"
echo 0 > "$SCRATCH/counter"

its::comment_issue() {
  local n
  n=$(($(cat "$SCRATCH/counter") + 1))
  echo "$n" > "$SCRATCH/counter"
  printf '%s' "$1" > "$SCRATCH/comment_${n}_issue.txt"
  printf '%s' "$2" > "$SCRATCH/comment_${n}_body.txt"
}

reset_log() { echo 0 > "$SCRATCH/counter"; rm -f "$SCRATCH"/comment_*; }
comment_count() { cat "$SCRATCH/counter"; }

# Source the command-string helper (normally sourced via load-config.sh) so
# the remediation commands exercise the real `/verb` vs `/<ns> verb` composition.
source "$REPO_ROOT/.autoducks/core/config/command-string.sh"

# Source the helper under test
source "$REPO_ROOT/.autoducks/core/feedback/notify-skip.sh"

# ---------------------------------------------------------------------------
# Test 1: per-agent remediation command
# ---------------------------------------------------------------------------
echo "[1] per-agent remediation command"

assert_agent_cmd() {
  local agent="$1" expect_cmd="$2"
  reset_log
  ( export AUTODUCKS_AGENT="$agent"; notify_skip "100" )
  local body
  body=$(cat "$SCRATCH/comment_1_body.txt")
  if echo "$body" | grep -qF "\`$expect_cmd\`"; then
    pass "$agent: body names $expect_cmd"
  else
    fail "$agent: expected $expect_cmd missing: $body"
  fi
}

assert_agent_cmd "architect" "/architect"
assert_agent_cmd "engineer"  "/engineer"
assert_agent_cmd "developer" "/execute"
assert_agent_cmd "fix"       "/fix"
assert_agent_cmd "defer"     "/defer"
assert_agent_cmd "rework"    "/rework"
assert_agent_cmd "resolver"  "/resolve"
assert_agent_cmd "reviewer"  "/review"

# ---------------------------------------------------------------------------
# Test 2: reviewer keeps "Auto-review skipped"; non-reviewer agents do not
# claim "auto-review" and do not point at /review
# ---------------------------------------------------------------------------
echo "[2] reviewer wording preserved; non-reviewer wording generalized"

reset_log
( export AUTODUCKS_AGENT="reviewer"; notify_skip "100" )
BODY=$(cat "$SCRATCH/comment_1_body.txt")
if echo "$BODY" | grep -qF "Auto-review skipped"; then
  pass "reviewer: body says Auto-review skipped"
else
  fail "reviewer: missing Auto-review skipped: $BODY"
fi
if echo "$BODY" | grep -qF '`/review`'; then
  pass "reviewer: body points at /review"
else
  fail "reviewer: does not point at /review: $BODY"
fi

for agent in architect engineer developer fix defer rework resolver; do
  reset_log
  ( export AUTODUCKS_AGENT="$agent"; notify_skip "100" )
  BODY=$(cat "$SCRATCH/comment_1_body.txt")
  if echo "$BODY" | grep -qi "auto-review"; then
    fail "$agent: body wrongly claims auto-review: $BODY"
  else
    pass "$agent: body does not claim auto-review"
  fi
  if echo "$BODY" | grep -qF '/review'; then
    fail "$agent: body wrongly points at /review: $BODY"
  else
    pass "$agent: body does not point at /review"
  fi
done

# ---------------------------------------------------------------------------
# Test 3: reason parameter overrides AUTODUCKS_AGENT
# ---------------------------------------------------------------------------
echo "[3] reason parameter overrides AUTODUCKS_AGENT"
reset_log
( export AUTODUCKS_AGENT="architect"; notify_skip "100" "developer" )
BODY=$(cat "$SCRATCH/comment_1_body.txt")
if echo "$BODY" | grep -qF '`/execute`'; then
  pass "reason override: developer reason yields /execute despite AUTODUCKS_AGENT=architect"
else
  fail "reason override did not take effect: $BODY"
fi

# ---------------------------------------------------------------------------
# Test 4: namespaced command via AUTODUCKS_COMMAND
# ---------------------------------------------------------------------------
echo "[4] AUTODUCKS_COMMAND namespacing"
reset_log
( export AUTODUCKS_AGENT="developer" AUTODUCKS_COMMAND="/ducks"; notify_skip "100" )
BODY=$(cat "$SCRATCH/comment_1_body.txt")
if echo "$BODY" | grep -qF '`/ducks execute`'; then
  pass "namespaced command renders /ducks execute"
else
  fail "namespaced command missing: $BODY"
fi

# ---------------------------------------------------------------------------
# Test 5: unset/unknown AUTODUCKS_AGENT falls back to /fix without erroring
# ---------------------------------------------------------------------------
echo "[5] unset/unknown AUTODUCKS_AGENT falls back to /fix"
reset_log
( unset AUTODUCKS_AGENT 2>/dev/null; notify_skip "100" )
BODY=$(cat "$SCRATCH/comment_1_body.txt")
if echo "$BODY" | grep -qF '`/fix`'; then
  pass "unset agent falls back to /fix"
else
  fail "unset agent did not fall back to /fix: $BODY"
fi

reset_log
( export AUTODUCKS_AGENT="totally-bogus"; notify_skip "100" )
BODY=$(cat "$SCRATCH/comment_1_body.txt")
if echo "$BODY" | grep -qF '`/fix`'; then
  pass "unknown agent falls back to /fix"
else
  fail "unknown agent did not fall back to /fix: $BODY"
fi

# ---------------------------------------------------------------------------
# Test 6: best-effort — exactly one comment posted, on the passed issue id
# ---------------------------------------------------------------------------
echo "[6] exactly one comment posted on the passed issue id"
reset_log
( export AUTODUCKS_AGENT="fix"; notify_skip "777" )
if [[ "$(comment_count)" -eq 1 ]]; then
  pass "posts exactly one comment"
else
  fail "expected 1 comment, got $(comment_count)"
fi
if [[ "$(cat "$SCRATCH/comment_1_issue.txt")" == "777" ]]; then
  pass "comment posted on the passed issue id"
else
  fail "wrong issue id: $(cat "$SCRATCH/comment_1_issue.txt")"
fi

# ---------------------------------------------------------------------------
# Test 7: anti-tampering rationale preserved; not softened into a failure
# ---------------------------------------------------------------------------
echo "[7] anti-tampering rationale preserved"
reset_log
( export AUTODUCKS_AGENT="fix"; notify_skip "100" )
BODY=$(cat "$SCRATCH/comment_1_body.txt")
if echo "$BODY" | grep -qF "claude-code-action" && echo "$BODY" | grep -qF "anti-tampering safeguard" && echo "$BODY" | grep -qF "expected, not a failure"; then
  pass "anti-tampering rationale present and framed as expected, not a failure"
else
  fail "anti-tampering rationale missing or altered: $BODY"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
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
