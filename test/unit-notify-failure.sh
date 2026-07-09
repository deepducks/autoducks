#!/usr/bin/env bash
# Unit tests for .autoducks/core/feedback/notify-failure.sh
# Run: bash test/unit-notify-failure.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

export REPO="acme/widgets"
export AUTODUCKS_COMMAND="${AUTODUCKS_COMMAND:-}"

# Scratch directory cleaned up on exit. Also back up/restore /tmp/work-summary.md
# since one test case writes to it (the real path notify_failure reads from).
SCRATCH=$(mktemp -d)
WORK_SUMMARY_BACKUP=""
if [[ -f /tmp/work-summary.md ]]; then
  WORK_SUMMARY_BACKUP="$SCRATCH/work-summary.orig"
  cp /tmp/work-summary.md "$WORK_SUMMARY_BACKUP"
fi
cleanup() {
  if [[ -n "$WORK_SUMMARY_BACKUP" ]]; then
    cp "$WORK_SUMMARY_BACKUP" /tmp/work-summary.md
  else
    rm -f /tmp/work-summary.md
  fi
  rm -rf "$SCRATCH"
}
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
# the retry hints exercise the real `/verb` vs `/<ns> verb` composition.
source "$REPO_ROOT/.autoducks/core/config/command-string.sh"

# Source the helper under test
source "$REPO_ROOT/.autoducks/core/feedback/notify-failure.sh"

# ---------------------------------------------------------------------------
# Test 1: two positional args — backward compat, posts exactly one comment
# ---------------------------------------------------------------------------
echo "[1] notify_failure <issue> <run> — backward compat"
reset_log
( unset _AUTODUCKS_NOTIFIED; notify_failure "100" "555" )
if [[ "$(comment_count)" -eq 1 ]]; then
  pass "posts exactly one comment"
else
  fail "expected 1 comment, got $(comment_count)"
fi
if [[ "$(cat "$SCRATCH/comment_1_issue.txt")" == "100" ]]; then
  pass "comment posted on the task issue"
else
  fail "wrong issue id: $(cat "$SCRATCH/comment_1_issue.txt")"
fi

# ---------------------------------------------------------------------------
# Test 2: three positional args — posts task comment AND feature comment
# ---------------------------------------------------------------------------
echo "[2] notify_failure <issue> <run> <feature> — backward compat"
reset_log
( unset _AUTODUCKS_NOTIFIED; notify_failure "101" "556" "999" )
if [[ "$(comment_count)" -eq 2 ]]; then
  pass "posts two comments (task + feature)"
else
  fail "expected 2 comments, got $(comment_count)"
fi
if [[ "$(cat "$SCRATCH/comment_1_issue.txt")" == "101" && "$(cat "$SCRATCH/comment_2_issue.txt")" == "999" ]]; then
  pass "comments target task issue then feature issue"
else
  fail "wrong issue targets: $(cat "$SCRATCH/comment_1_issue.txt") / $(cat "$SCRATCH/comment_2_issue.txt")"
fi
if grep -q "Task #101 failed" "$SCRATCH/comment_2_body.txt"; then
  pass "feature comment names the failing task"
else
  fail "feature comment missing task reference: $(cat "$SCRATCH/comment_2_body.txt")"
fi

# ---------------------------------------------------------------------------
# Test 3: parent-feature comment fires iff feature_issue_id is non-empty
# ---------------------------------------------------------------------------
echo "[3] parent-feature comment fires iff feature_issue_id non-empty"
reset_log
( unset _AUTODUCKS_NOTIFIED; notify_failure "102" "557" "" )
if [[ "$(comment_count)" -eq 1 ]]; then
  pass "empty feature_issue_id ⇒ no feature comment"
else
  fail "expected 1 comment with empty feature id, got $(comment_count)"
fi

# ---------------------------------------------------------------------------
# Test 4: category → diagnosis + retry command mapping
# ---------------------------------------------------------------------------
echo "[4] category → diagnosis/retry mapping"

assert_category() {
  local category="$1" expect_diagnosis="$2" expect_retry="$3"
  reset_log
  (
    unset _AUTODUCKS_NOTIFIED
    export AUTODUCKS_FAIL_CATEGORY="$category"
    notify_failure "200" "600"
  )
  local body
  body=$(cat "$SCRATCH/comment_1_body.txt")
  if echo "$body" | grep -qF "$expect_diagnosis"; then
    pass "$category: diagnosis line present"
  else
    fail "$category: diagnosis line missing: $body"
  fi
  if echo "$body" | grep -qF "$expect_retry"; then
    pass "$category: retry command present"
  else
    fail "$category: retry command missing: $body"
  fi
  if echo "$body" | grep -qF "\`$category\`"; then
    pass "$category: category echoed in message"
  else
    fail "$category: category not echoed: $body"
  fi
}

assert_category "merge-conflict" \
  "The task PR could not be merged into the feature branch" \
  '`/fix` on this task'

assert_category "no-changes" \
  "The agent finished but produced no code changes." \
  '`/fix` (or refine the issue spec and re-run)'

assert_category "scope-missing" \
  "The agent did not produce the expected output file" \
  're-run `/architect` or `/engineer`'

assert_category "parse" \
  "The tactical plan could not be parsed into tasks." \
  're-run `/engineer`'

assert_category "max_turns" \
  "partial work has been preserved" \
  '`/execute turns=100` to resume from the partial branch'

assert_category "infra" \
  "The run hit an unexpected error before it could finish" \
  '`/fix` to retry'

# ---------------------------------------------------------------------------
# Test 4b: max_turns retry budget derives from MAX_TURNS (double + cap + fallback)
# ---------------------------------------------------------------------------
echo "[4b] max_turns retry budget: double + cap + fallback"

assert_max_turns_budget() {
  local label="$1" max_turns_value="$2" expect_turns="$3"
  reset_log
  (
    unset _AUTODUCKS_NOTIFIED
    export AUTODUCKS_FAIL_CATEGORY="max_turns"
    if [[ -n "$max_turns_value" ]]; then
      export MAX_TURNS="$max_turns_value"
    else
      unset MAX_TURNS
    fi
    notify_failure "203" "603"
  )
  local body
  body=$(cat "$SCRATCH/comment_1_body.txt")
  if echo "$body" | grep -qF "turns=$expect_turns"; then
    pass "$label: suggests turns=$expect_turns"
  else
    fail "$label: expected turns=$expect_turns missing: $body"
  fi
}

assert_max_turns_budget "MAX_TURNS=200 doubles" "200" "400"
assert_max_turns_budget "MAX_TURNS=800 caps at 1000" "800" "1000"
assert_max_turns_budget "MAX_TURNS=abc malformed falls back" "abc" "100"

# ---------------------------------------------------------------------------
# Test 5: unknown/unset category defaults to infra
# ---------------------------------------------------------------------------
echo "[5] unknown/unset AUTODUCKS_FAIL_CATEGORY defaults to infra"
reset_log
( unset _AUTODUCKS_NOTIFIED AUTODUCKS_FAIL_CATEGORY; notify_failure "201" "601" )
BODY=$(cat "$SCRATCH/comment_1_body.txt")
if echo "$BODY" | grep -qF "The run hit an unexpected error before it could finish"; then
  pass "unset category ⇒ infra diagnosis"
else
  fail "unset category did not default to infra: $BODY"
fi
if echo "$BODY" | grep -qF '`infra`'; then
  pass "unset category ⇒ infra label"
else
  fail "unset category did not echo infra label: $BODY"
fi

reset_log
( unset _AUTODUCKS_NOTIFIED; export AUTODUCKS_FAIL_CATEGORY="totally-bogus"; notify_failure "202" "602" )
BODY=$(cat "$SCRATCH/comment_1_body.txt")
if echo "$BODY" | grep -qF "The run hit an unexpected error before it could finish"; then
  pass "unrecognized category ⇒ infra diagnosis"
else
  fail "unrecognized category did not default to infra: $BODY"
fi

# ---------------------------------------------------------------------------
# Test 6: max_turns appends preserved branch + work-summary contents
# ---------------------------------------------------------------------------
echo "[6] max_turns includes preserved branch and work-summary contents"
reset_log
echo "Implemented the widget cache; tests still failing on edge case X." > /tmp/work-summary.md
(
  unset _AUTODUCKS_NOTIFIED
  export AUTODUCKS_FAIL_CATEGORY="max_turns"
  export AUTODUCKS_FAIL_BRANCH="feature/300-task-widget"
  notify_failure "300" "700"
)
BODY=$(cat "$SCRATCH/comment_1_body.txt")
if echo "$BODY" | grep -qF "feature/300-task-widget"; then
  pass "preserved branch name included"
else
  fail "preserved branch missing: $BODY"
fi
if echo "$BODY" | grep -qF "widget cache"; then
  pass "work-summary contents included"
else
  fail "work-summary contents missing: $BODY"
fi
rm -f /tmp/work-summary.md

# ---------------------------------------------------------------------------
# Test 7: second notify_failure call in the same process is a no-op
# ---------------------------------------------------------------------------
echo "[7] second call in same process is a no-op"
reset_log
(
  unset _AUTODUCKS_NOTIFIED
  notify_failure "400" "800"
  notify_failure "401" "801"
)
if [[ "$(comment_count)" -eq 1 ]]; then
  pass "second call posted no additional comment"
else
  fail "expected 1 comment after two calls, got $(comment_count)"
fi
if [[ "$(cat "$SCRATCH/comment_1_issue.txt")" == "400" ]]; then
  pass "only the first call's comment was posted"
else
  fail "wrong comment survived: $(cat "$SCRATCH/comment_1_issue.txt")"
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
