#!/usr/bin/env bash
set -euo pipefail

# Check if a specific task is already being worked on.
# Usage: prevent_duplicate_dispatch <task_number> <feature_branch>
# Returns 0 if safe to dispatch, 1 if a duplicate is detected.
#
# Only per-task signals are inspected. GitHub's API does not expose
# workflow_dispatch inputs on the run object, and the run's head_branch
# reflects the dispatch ref rather than the task branch (which is created
# inside execution/pre.sh), so no reliable per-task match exists for an
# in-progress workflow run. The dispatch→PR window is protected by the
# execution-side idempotency guard in .autoducks/agents/execution/pre.sh.
prevent_duplicate_dispatch() {
  local task_number="$1"
  local feature_branch="$2"

  local open_prs
  open_prs=$(git::list_open_prs "$feature_branch")
  if echo "$open_prs" | jq -e --arg t "$task_number" \
    '.[] | select(.body | test("(?i)(fixes|closes|resolves)\\s+#" + $t + "\\b"))' &>/dev/null; then
    echo "::notice::Task #$task_number already has an open PR"
    return 1
  fi

  return 0
}
