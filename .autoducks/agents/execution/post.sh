#!/usr/bin/env bash
set -euo pipefail
export AUTODUCKS_AGENT="execution"
source "$(dirname "${BASH_SOURCE[0]}")/../../core/config/load-config.sh"
source "$AUTODUCKS_ROOT/core/feedback/react-to-comment.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-failure.sh"
source "$AUTODUCKS_ROOT/core/robustness/assert-changes.sh"
source "$AUTODUCKS_ROOT/core/orchestration/trigger-loop-closure.sh"
source "$AUTODUCKS_ROOT/core/feedback/progress-labels.sh"

# Reconstruct state from git (pre.sh exports don't persist across GHA steps)
TASK_BRANCH=$(git rev-parse --abbrev-ref HEAD)
BASE_BRANCH="${BASE_BRANCH:-$AUTODUCKS_BASE_BRANCH}"
FEATURE_NUM=""
if [[ "$BASE_BRANCH" =~ ^feature/([0-9]+) ]]; then
  FEATURE_NUM="${BASH_REMATCH[1]}"
fi

# Check agent made changes
if ! assert_changes; then
  notify_failure "$ISSUE_NUM" "$RUN_ID" "${FEATURE_NUM:+$FEATURE_NUM}"
  react_to_comment "${COMMENT_ID:-}" "confused"
  progress_labels::abort "$ISSUE_NUM" "Work:progress"
  exit 1
fi

# Commit and push
git add -A
git commit -m "Implement issue #${ISSUE_NUM}" || true
git::push_branch "$TASK_BRANCH"

# Get issue title for PR
ISSUE_TITLE=$(its::get_issue "$ISSUE_NUM" | jq -r '.title')
PR_TITLE="Task #$ISSUE_NUM: $ISSUE_TITLE"

# Create PR
PR_NUM=$(git::create_pr "$TASK_BRANCH" "$BASE_BRANCH" "$PR_TITLE" "fixes #${ISSUE_NUM}")

if [[ -n "${FEATURE_NUM:-}" && "$FEATURE_NUM" != "0" ]]; then
  # Scenario B: task with feature parent — auto-merge with rebase retry
  MERGE_OK=false
  for attempt in 1 2 3; do
    if git::merge_pr "$PR_NUM"; then
      MERGE_OK=true
      break
    fi
    echo "Merge attempt $attempt failed — rebasing onto $BASE_BRANCH..."
    git fetch origin "$BASE_BRANCH"
    if ! git rebase "origin/$BASE_BRANCH"; then
      echo "Rebase conflict on attempt $attempt — aborting"
      git rebase --abort 2>/dev/null || true
      break
    fi
    git push --force-with-lease origin "$TASK_BRANCH"
  done

  if [[ "$MERGE_OK" != "true" ]]; then
    notify_failure "$ISSUE_NUM" "$RUN_ID" "$FEATURE_NUM"
    react_to_comment "${COMMENT_ID:-}" "confused"
    progress_labels::abort "$ISSUE_NUM" "Work:progress"
    exit 1
  fi

  # Sub-PRs merge into the feature branch, not the default branch, so
  # GitHub's "fixes #N" auto-close does not fire. Close the task explicitly.
  its::close_issue "$ISSUE_NUM" \
    "Auto-closed by execution agent after merging sub-PR #$PR_NUM into \`$BASE_BRANCH\`." \
    "completed" \
    2>/dev/null || echo "::warning::Could not close task #$ISSUE_NUM"

  # Trigger wave orchestrator to continue (non-fatal — PR merge event is the primary trigger)
  trigger_loop_closure "$FEATURE_NUM" || true
fi

# Scenario A (orphan task): PR goes to main, no auto-merge — human review needed

react_to_comment "${COMMENT_ID:-}" "+1"

progress_labels::finish "$ISSUE_NUM" "Work:progress" "Work:done"

its::comment_issue "$ISSUE_NUM" "✅ Implementation complete. PR #$PR_NUM created.

_Ran with \`${MODEL:-unknown}\` at reasoning \`${REASONING:-unknown}\`._"
