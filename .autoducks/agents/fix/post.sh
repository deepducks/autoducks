#!/usr/bin/env bash
set -euo pipefail
export AUTODUCKS_AGENT="fix"
source "$(dirname "${BASH_SOURCE[0]}")/../../core/config/load-config.sh"
source "$AUTODUCKS_ROOT/core/feedback/react-to-comment.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-failure.sh"
source "$AUTODUCKS_ROOT/core/robustness/assert-changes.sh"
source "$AUTODUCKS_ROOT/core/orchestration/trigger-loop-closure.sh"

# Reconstruct state from git (pre.sh exports don't persist across GHA steps)
TASK_BRANCH=$(git rev-parse --abbrev-ref HEAD)
BASE_BRANCH="${BASE_BRANCH:-$AUTODUCKS_BASE_BRANCH}"
FEATURE_NUM=""
if [[ "$TASK_BRANCH" =~ ^feature/([0-9]+)-issue- ]]; then
  FEATURE_NUM="${BASH_REMATCH[1]}"
fi

# Check for changes (allow existing commits on reused branch)
assert_changes || true

# Commit and push (only if there are staged changes)
if ! git diff --cached --quiet 2>/dev/null; then
  git commit -m "Fix implementation for issue #${ISSUE_NUM}"
fi
git::push_branch "$TASK_BRANCH"

# Check for existing PR
EXISTING_PR=$(gh pr list --repo "$REPO" --head "$TASK_BRANCH" --base "$BASE_BRANCH" --json number --jq '.[0].number // empty' 2>/dev/null || true)

if [[ -z "$EXISTING_PR" ]]; then
  ISSUE_TITLE=$(its::get_issue "$ISSUE_NUM" | jq -r '.title')
  PR_NUM=$(git::create_pr "$TASK_BRANCH" "$BASE_BRANCH" "Fix: $ISSUE_TITLE" "fixes #${ISSUE_NUM}")
else
  PR_NUM="$EXISTING_PR"
fi

if [[ -n "${FEATURE_NUM:-}" && "$FEATURE_NUM" != "0" ]]; then
  if ! git::merge_pr "$PR_NUM"; then
    notify_failure "$ISSUE_NUM" "$RUN_ID" "$FEATURE_NUM"
    react_to_comment "$COMMENT_ID" "confused"
    exit 1
  fi
  trigger_loop_closure "$FEATURE_NUM"
fi

react_to_comment "$COMMENT_ID" "+1"
its::comment_issue "$ISSUE_NUM" "✅ Fix applied. PR #$PR_NUM."
