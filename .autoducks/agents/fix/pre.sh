#!/usr/bin/env bash
set -euo pipefail
export AUTODUCKS_AGENT="fix"
source "$(dirname "${BASH_SOURCE[0]}")/../../core/config/load-config.sh"
source "$AUTODUCKS_ROOT/core/feedback/react-to-comment.sh"

react_to_comment "$COMMENT_ID" "eyes"

BASE_BRANCH="${BASE_BRANCH:-$AUTODUCKS_BASE_BRANCH}"

# Extract feature number from base branch
FEATURE_NUM=""
if [[ "$BASE_BRANCH" =~ ^feature/([0-9]+) ]]; then
  FEATURE_NUM="${BASH_REMATCH[1]}"
fi

# Find existing partial branch from a previous attempt
EXISTING_BRANCH=$(git::find_branches_matching "feature/${FEATURE_NUM:-0}-issue-${ISSUE_NUM}-" | sort | tail -1 || true)

if [[ -n "$EXISTING_BRANCH" ]]; then
  TASK_BRANCH="$EXISTING_BRANCH"
  git checkout "$TASK_BRANCH" 2>/dev/null || git checkout -b "$TASK_BRANCH" "origin/$TASK_BRANCH"
else
  TASK_BRANCH="feature/${FEATURE_NUM:-0}-issue-${ISSUE_NUM}-fix-$(date +%s)"
  git::configure_identity
  git checkout -b "$TASK_BRANCH"
fi

# Prepare task spec
its::get_issue "$ISSUE_NUM" | jq -r '"# " + .title + "\n\n" + .body' > /tmp/task-spec.md

# Prepare failure context (recent comments)
its::list_comments "$ISSUE_NUM" 10 | jq -r '.[] | "## " + .author + "\n\n" + .body + "\n\n---\n"' > /tmp/failure-context.md

export TASK_BRANCH BASE_BRANCH FEATURE_NUM EXISTING_BRANCH
