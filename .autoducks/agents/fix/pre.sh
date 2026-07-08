#!/usr/bin/env bash
set -euo pipefail
export AUTODUCKS_AGENT="fix"

source "$(dirname "${BASH_SOURCE[0]}")/../../core/config/load-config.sh"
source "$AUTODUCKS_ROOT/core/feedback/react-to-comment.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-failure.sh"
source "$AUTODUCKS_ROOT/core/feedback/progress-labels.sh"
source "$AUTODUCKS_ROOT/core/feedback/status-comment.sh"
source "$AUTODUCKS_ROOT/core/orchestration/branch-prefix.sh"

rm -f "$AUTODUCKS_PRE_FAILED_MARKER"
mkdir -p "$AUTODUCKS_MARKER_DIR"

react_to_comment "$COMMENT_ID" "eyes"
status_comment::start "$ISSUE_NUM"

PR_BASE_BRANCH="${BASE_BRANCH:-$AUTODUCKS_INTEGRATION_BRANCH}"
BASE_BRANCH="${BASE_BRANCH:-$AUTODUCKS_BASE_BRANCH}"

FEATURE_NUM=$(pipeline_branch_number "$BASE_BRANCH")
TASK_PREFIX=$(branch_prefix_of "$BASE_BRANCH")

trap '_rc=$?; notify_failure "$ISSUE_NUM" "$RUN_ID" "${FEATURE_NUM:-}" 2>/dev/null || true; \
      status_comment::fail "$ISSUE_NUM" 2>/dev/null || true; \
      react_to_comment "${COMMENT_ID:-}" "confused" 2>/dev/null || true; \
      progress_labels::abort "$ISSUE_NUM" "Work:coding" 2>/dev/null || true; \
      touch "$AUTODUCKS_PRE_FAILED_MARKER"; \
      exit $_rc' ERR

# Find the newest existing task branch for this issue — task branches carry
# either pipeline prefix (feature/ or fix/, D10), so search both.
EXISTING_BRANCH=$( { git::find_branches_matching "feature/${FEATURE_NUM:-0}-issue-${ISSUE_NUM}-" ; \
                     git::find_branches_matching "fix/${FEATURE_NUM:-0}-issue-${ISSUE_NUM}-" ; } \
                   | sort | tail -1 || true)

if [[ -n "$EXISTING_BRANCH" ]]; then
  TASK_BRANCH="$EXISTING_BRANCH"
  git checkout "$TASK_BRANCH" 2>/dev/null || git checkout -b "$TASK_BRANCH" "origin/$TASK_BRANCH"
else
  TASK_BRANCH="${TASK_PREFIX}/${FEATURE_NUM:-0}-issue-${ISSUE_NUM}-fix-$(date +%s)"
  git::configure_identity
  git checkout -b "$TASK_BRANCH"
fi

# Prepare task spec
its::get_issue "$ISSUE_NUM" | jq -r '"# " + .title + "\n\n" + .body' > /tmp/task-spec.md

# Prepare failure context (recent comments)
its::list_comments "$ISSUE_NUM" 10 | jq -r '.[] | "## " + .author + "\n\n" + .body + "\n\n---\n"' > /tmp/failure-context.md

export TASK_BRANCH BASE_BRANCH PR_BASE_BRANCH FEATURE_NUM EXISTING_BRANCH
