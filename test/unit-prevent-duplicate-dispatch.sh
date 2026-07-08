#!/usr/bin/env bash
# Unit tests for .autoducks/core/orchestration/prevent-duplicate-dispatch.sh
# Run: bash test/unit-prevent-duplicate-dispatch.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD_SH="$REPO_ROOT/.autoducks/core/orchestration/prevent-duplicate-dispatch.sh"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

# git::list_open_prs stub — returns whatever JSON was staged in $MOCK_OPEN_PRS
# for this test case. Offline and side-effect-free: no gh, no network.
MOCK_OPEN_PRS="[]"
git::list_open_prs() {
  printf '%s' "$MOCK_OPEN_PRS"
}

source "$GUARD_SH"

FEATURE_BRANCH="feature/99-widget"

# ---------------------------------------------------------------------------
# Test 1: open PR references the task via fixes/closes/resolves #N -> skip
# ---------------------------------------------------------------------------
echo "[1] open PR referencing the task -> skip (non-zero)"
MOCK_OPEN_PRS=$(jq -n '[{number: 555, title: "Task 5 done", headRefName: "feature/99-widget/task/5-thing",
  body: "Implements the thing.\n\nFixes #5", mergeable: "MERGEABLE", mergeStateStatus: "CLEAN"}]')

if prevent_duplicate_dispatch 5 "$FEATURE_BRANCH"; then
  fail "expected non-zero (skip) when an open PR references the task, got 0 (dispatch)"
else
  pass "returns non-zero when an open PR references the task"
fi

# closes/resolves keywords and case-insensitivity
for kw in "closes" "Resolves" "CLOSES"; do
  MOCK_OPEN_PRS=$(jq -n --arg kw "$kw" \
    '[{number: 556, title: "t", headRefName: "b", body: ("See " + $kw + " #7"),
       mergeable: "MERGEABLE", mergeStateStatus: "CLEAN"}]')
  if prevent_duplicate_dispatch 7 "$FEATURE_BRANCH"; then
    fail "expected skip for keyword '$kw', got dispatch"
  else
    pass "skip fires for keyword '$kw'"
  fi
done

# ---------------------------------------------------------------------------
# Test 2: no open PR at all -> dispatch (merged history is handled by is_done,
# not this guard, so a task whose only PR merged/closed simply has no open PR)
# ---------------------------------------------------------------------------
echo "[2] no open PR -> dispatch (zero)"
MOCK_OPEN_PRS="[]"
if prevent_duplicate_dispatch 5 "$FEATURE_BRANCH"; then
  pass "returns 0 when there is no open PR"
else
  fail "expected 0 (dispatch) with no open PR, got non-zero (skip)"
fi

# ---------------------------------------------------------------------------
# Test 3: only an open PR for a *different* task -> dispatch
# ---------------------------------------------------------------------------
echo "[3] open PR referencing a different task -> dispatch (zero)"
MOCK_OPEN_PRS=$(jq -n '[{number: 600, title: "Task 9", headRefName: "feature/99-widget/task/9-thing",
  body: "Fixes #9", mergeable: "MERGEABLE", mergeStateStatus: "CLEAN"}]')
if prevent_duplicate_dispatch 5 "$FEATURE_BRANCH"; then
  pass "returns 0 when the only open PR references a different task"
else
  fail "expected 0 (dispatch) when only a different task has an open PR, got skip"
fi

# ---------------------------------------------------------------------------
# Test 4: word-boundary matching — task #1 must not false-positive on "#12"
# ---------------------------------------------------------------------------
echo "[4] boundary case: task #1 vs PR referencing #12"
MOCK_OPEN_PRS=$(jq -n '[{number: 601, title: "Task 12", headRefName: "feature/99-widget/task/12-thing",
  body: "Fixes #12", mergeable: "MERGEABLE", mergeStateStatus: "CLEAN"}]')
if prevent_duplicate_dispatch 1 "$FEATURE_BRANCH"; then
  pass "task #1 is not falsely matched by a PR referencing #12"
else
  fail "task #1 was incorrectly skipped due to a PR referencing #12"
fi

# and the reverse: task #12 must still match a PR referencing exactly #12
if prevent_duplicate_dispatch 12 "$FEATURE_BRANCH"; then
  fail "task #12 should have been skipped by its own open PR referencing #12"
else
  pass "task #12 is correctly matched by a PR referencing #12"
fi

# ---------------------------------------------------------------------------
# Test 5: classification helper — healthy vs blocked open PR
# ---------------------------------------------------------------------------
echo "[5] task_blocked_pr_number classification"

if declare -f task_blocked_pr_number > /dev/null; then
  # 5a. mergeable=MERGEABLE, mergeStateStatus=CLEAN -> healthy, not blocked
  MOCK_OPEN_PRS=$(jq -n '[{number: 700, title: "Task 20", headRefName: "feature/99-widget/task/20-thing",
    body: "Fixes #20", mergeable: "MERGEABLE", mergeStateStatus: "CLEAN"}]')
  if task_blocked_pr_number 20 "$FEATURE_BRANCH" > /dev/null; then
    fail "healthy PR (MERGEABLE/CLEAN) was reported as blocked"
  else
    pass "healthy PR (MERGEABLE/CLEAN) is not reported as blocked"
  fi

  # 5b. mergeable=CONFLICTING -> blocked, echoes the PR number
  MOCK_OPEN_PRS=$(jq -n '[{number: 701, title: "Task 21", headRefName: "feature/99-widget/task/21-thing",
    body: "Fixes #21", mergeable: "CONFLICTING", mergeStateStatus: "DIRTY"}]')
  BLOCKED_RC=0
  BLOCKED_OUT="$(task_blocked_pr_number 21 "$FEATURE_BRANCH")" || BLOCKED_RC=$?
  if [[ "$BLOCKED_RC" -eq 0 && "$BLOCKED_OUT" == "701" ]]; then
    pass "CONFLICTING PR is reported blocked with PR number 701"
  else
    fail "expected blocked PR 701 (rc=0), got rc=$BLOCKED_RC out='$BLOCKED_OUT'"
  fi

  # 5c. mergeable=MERGEABLE but mergeStateStatus=DIRTY -> still blocked
  MOCK_OPEN_PRS=$(jq -n '[{number: 702, title: "Task 22", headRefName: "feature/99-widget/task/22-thing",
    body: "Fixes #22", mergeable: "MERGEABLE", mergeStateStatus: "DIRTY"}]')
  BLOCKED_RC=0
  BLOCKED_OUT="$(task_blocked_pr_number 22 "$FEATURE_BRANCH")" || BLOCKED_RC=$?
  if [[ "$BLOCKED_RC" -eq 0 && "$BLOCKED_OUT" == "702" ]]; then
    pass "DIRTY mergeStateStatus is reported blocked with PR number 702"
  else
    fail "expected blocked PR 702 (rc=0), got rc=$BLOCKED_RC out='$BLOCKED_OUT'"
  fi

  # 5d. no open PR for the task at all -> not blocked (rc=1, no output)
  MOCK_OPEN_PRS="[]"
  BLOCKED_RC=0
  BLOCKED_OUT="$(task_blocked_pr_number 23 "$FEATURE_BRANCH")" || BLOCKED_RC=$?
  if [[ "$BLOCKED_RC" -ne 0 && -z "$BLOCKED_OUT" ]]; then
    pass "no open PR -> not reported as blocked, no output"
  else
    fail "expected rc!=0 and empty output with no open PR, got rc=$BLOCKED_RC out='$BLOCKED_OUT'"
  fi
else
  echo "  (skipped: task_blocked_pr_number not defined by this version of the guard)"
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
