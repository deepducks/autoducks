#!/usr/bin/env bash
set -euo pipefail
export AUTODUCKS_AGENT="execution"
source "$(dirname "${BASH_SOURCE[0]}")/../../core/config/load-config.sh"
source "$AUTODUCKS_ROOT/core/feedback/react-to-comment.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-failure.sh"
source "$AUTODUCKS_ROOT/core/robustness/assert-changes.sh"
source "$AUTODUCKS_ROOT/core/orchestration/trigger-loop-closure.sh"

# Check agent made changes
if ! assert_changes; then
  notify_failure "$ISSUE_NUM" "$RUN_ID" "${FEATURE_NUM:+$FEATURE_NUM}"
  react_to_comment "${COMMENT_ID:-}" "confused"
  exit 1
fi

# Commit and push
git commit -m "Implement issue #${ISSUE_NUM}"
git::push_branch "$TASK_BRANCH"

# Get issue title for PR
ISSUE_TITLE=$(its::get_issue "$ISSUE_NUM" | jq -r '.title')
PR_TITLE="Task #$ISSUE_NUM: $ISSUE_TITLE"

# Create PR
PR_NUM=$(git::create_pr "$TASK_BRANCH" "$BASE_BRANCH" "$PR_TITLE" "fixes #${ISSUE_NUM}")

if [[ -n "${FEATURE_NUM:-}" && "$FEATURE_NUM" != "0" ]]; then
  # Scenario B: task with feature parent — auto-merge
  if ! git::merge_pr "$PR_NUM"; then
    notify_failure "$ISSUE_NUM" "$RUN_ID" "$FEATURE_NUM"
    react_to_comment "${COMMENT_ID:-}" "confused"
    exit 1
  fi

  # Trigger wave orchestrator to continue
  trigger_loop_closure "$FEATURE_NUM"
fi

# Scenario A (orphan task): PR goes to main, no auto-merge — human review needed

react_to_comment "${COMMENT_ID:-}" "+1"

its::comment_issue "$ISSUE_NUM" "✅ Implementation complete. PR #$PR_NUM created."
