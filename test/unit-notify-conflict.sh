#!/usr/bin/env bash
# Unit tests for notify_conflict in .autoducks/core/feedback/notify-failure.sh
# Run: bash test/unit-notify-conflict.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOTIFY_SH="$REPO_ROOT/.autoducks/core/feedback/notify-failure.sh"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

# Mock ITS — stubs its::comment_issue to capture arguments (issue id + full
# body) so we can assert on what was posted without hitting a real GitHub API.
# Each call is recorded as one file per issue id under $LOGDIR (bodies can
# span multiple lines, so a single flat log can't be grepped line-by-line).
its::comment_issue() {
  echo "$1" >> "$LOGDIR/order.txt"
  printf '%s' "$2" >> "$LOGDIR/issue-$1.body"
}

source "$NOTIFY_SH"

export REPO="x/y"

# ---------------------------------------------------------------------------
# Test 1: notify_conflict without feature_issue_id — single task comment only
# ---------------------------------------------------------------------------
echo "[1] notify_conflict without feature_issue_id"
LOGDIR="$SCRATCH/log1"
mkdir -p "$LOGDIR"
notify_conflict 42 999 "feature/foo-bar" 123

if [[ "$(wc -l < "$LOGDIR/order.txt")" -eq 1 ]]; then
  pass "posts exactly one comment"
else
  fail "expected exactly 1 comment, got: $(cat "$LOGDIR/order.txt")"
fi

if [[ -f "$LOGDIR/issue-42.body" ]]; then
  pass "posted comment on task issue #42"
else
  fail "missing comment on task issue #42"
fi

task_body="$(cat "$LOGDIR/issue-42.body" 2>/dev/null || true)"
if echo "$task_body" | grep -q 'feature/foo-bar'; then
  pass "body includes branch name"
else
  fail "body missing branch name: $task_body"
fi

if echo "$task_body" | grep -q '#123'; then
  pass "body includes PR number"
else
  fail "body missing PR number: $task_body"
fi

if echo "$task_body" | grep -qi 'conflict'; then
  pass "body mentions conflict"
else
  fail "body missing the word 'conflict': $task_body"
fi

# ---------------------------------------------------------------------------
# Test 2: notify_conflict with feature_issue_id — also posts feature comment
# ---------------------------------------------------------------------------
echo "[2] notify_conflict with feature_issue_id"
LOGDIR="$SCRATCH/log2"
mkdir -p "$LOGDIR"
notify_conflict 42 999 "feature/foo-bar" 123 7

if [[ "$(wc -l < "$LOGDIR/order.txt")" -eq 2 ]]; then
  pass "posts exactly two comments"
else
  fail "expected exactly 2 comments, got: $(cat "$LOGDIR/order.txt")"
fi

if [[ -f "$LOGDIR/issue-42.body" ]]; then
  pass "still posts task-issue comment"
else
  fail "missing task-issue comment"
fi

if [[ -f "$LOGDIR/issue-7.body" ]]; then
  pass "posted comment on feature issue #7"
else
  fail "missing comment on feature issue #7"
fi

feature_body="$(cat "$LOGDIR/issue-7.body" 2>/dev/null || true)"
if echo "$feature_body" | grep -q 'feature/foo-bar' && echo "$feature_body" | grep -q '#123' && echo "$feature_body" | grep -qi 'conflict'; then
  pass "feature comment references branch, PR, and conflict"
else
  fail "feature comment missing expected content: $feature_body"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== notify_conflict unit test summary ==="
echo "  Pass: $PASS"
echo "  Fail: $FAIL"
if [[ "$FAIL" -eq 0 ]]; then
  echo "✅ All tests passed."
  exit 0
else
  echo "❌ $FAIL test(s) failed."
  exit 1
fi
