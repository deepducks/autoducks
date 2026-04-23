#!/usr/bin/env bash
set -euo pipefail

# Check if a task is already being worked on
# Usage: prevent_duplicate_dispatch <task_number> <feature_branch> <workflow_name>
# Returns 0 if safe to dispatch, 1 if duplicate found
prevent_duplicate_dispatch() {
  local task_number="$1"
  local feature_branch="$2"
  local workflow_name="${3:-autoducks-execute.yml}"

  # Check for existing open PR
  local open_prs
  open_prs=$(git::list_open_prs "$feature_branch")
  if echo "$open_prs" | jq -e --arg t "$task_number" \
    '.[] | select(.body | test("(?i)(fixes|closes|resolves)\\s+#" + $t + "\\b"))' &>/dev/null; then
    echo "::notice::Task #$task_number already has an open PR"
    return 1
  fi

  # Check for in-progress workflow run
  local runs
  runs=$(git::list_runs "$workflow_name" "in_progress")
  if echo "$runs" | jq -e 'length > 0' &>/dev/null; then
    echo "::notice::Workflow $workflow_name has in-progress runs"
    return 1
  fi

  return 0
}
