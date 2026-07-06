#!/usr/bin/env bash
set -euo pipefail
export AUTODUCKS_AGENT="execution"
source "$(dirname "${BASH_SOURCE[0]}")/../../core/config/load-config.sh"
source "$AUTODUCKS_ROOT/core/feedback/react-to-comment.sh"
source "$AUTODUCKS_ROOT/core/robustness/wait-for-branch.sh"

react_to_comment "${COMMENT_ID:-}" "eyes"

# Determine base branch and issue number
# These come from the runtime as env vars: ISSUE_NUM, BASE_BRANCH
BASE_BRANCH="${BASE_BRANCH:-$AUTODUCKS_BASE_BRANCH}"

# If base branch is a feature branch, extract feature number
FEATURE_NUM=""
if [[ "$BASE_BRANCH" =~ ^feature/([0-9]+) ]]; then
  FEATURE_NUM="${BASH_REMATCH[1]}"
fi

# Idempotency guard: bail if this task already has an open PR on the feature branch.
# Closes the window between orchestrator dispatch and PR creation, where two
# orchestrator runs may both pass prevent_duplicate_dispatch's open-PR check.
if [[ -n "$FEATURE_NUM" ]]; then
  EXISTING_PR=$(git::list_open_prs "$BASE_BRANCH" \
    | jq -r --arg t "$ISSUE_NUM" \
        '[.[] | select(.body | test("(?i)(fixes|closes|resolves)\\s+#" + $t + "\\b"))] | .[0].number // empty')
  if [[ -n "$EXISTING_PR" ]]; then
    echo "::notice::Task #$ISSUE_NUM already has open PR #$EXISTING_PR — skipping duplicate execution."
    react_to_comment "${COMMENT_ID:-}" "+1" 2>/dev/null || true
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
      echo "duplicate_skip=true" >> "$GITHUB_OUTPUT"
    fi
    exit 0
  fi
fi

# Wait for base branch to be visible
if [[ "$BASE_BRANCH" != "$AUTODUCKS_BASE_BRANCH" ]]; then
  wait_for_branch "$BASE_BRANCH"
fi

# Generate task branch name
SLUG=$(git::generate_slug "$ISSUE_NUM" "$(its::get_issue "$ISSUE_NUM" | jq -r '.title')")
TASK_BRANCH="feature/${FEATURE_NUM:-0}-issue-${ISSUE_NUM}-$(date +%s)"

# Configure git and create task branch from base
git::configure_identity
git fetch origin "$BASE_BRANCH" 2>/dev/null || true
git checkout "$BASE_BRANCH" 2>/dev/null || true
git checkout -b "$TASK_BRANCH"

# Prepare task spec for the LLM
its::get_issue "$ISSUE_NUM" | jq -r '"# " + .title + "\n\n" + .body' > /tmp/task-spec.md

# Export for post.sh
export TASK_BRANCH BASE_BRANCH FEATURE_NUM
