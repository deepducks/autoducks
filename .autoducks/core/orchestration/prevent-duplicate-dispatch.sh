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
# execution-side idempotency guard in .autoducks/agents/developer/pre.sh.
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

# Classify a task's already-open PR (the one that made prevent_duplicate_dispatch
# skip it) as blocked vs healthy/in-flight. A PR is blocked when GitHub reports it
# as unmergeable — the same signal developer/post.sh's merge-retry loop treats as a
# real conflict (notify_conflict). Echoes the blocked PR's number and returns 0 if
# blocked; returns 1 (no output) if the task has no open PR or that PR is healthy.
# Usage: task_blocked_pr_number <task_number> <feature_branch>
task_blocked_pr_number() {
  local task_number="$1"
  local feature_branch="$2"

  local open_prs blocked_pr
  open_prs=$(git::list_open_prs "$feature_branch")
  blocked_pr=$(echo "$open_prs" | jq -r --arg t "$task_number" \
    '[.[] | select(.body | test("(?i)(fixes|closes|resolves)\\s+#" + $t + "\\b"))
          | select(.mergeable == "CONFLICTING" or .mergeStateStatus == "DIRTY")]
     | .[0].number // empty')

  [[ -z "$blocked_pr" ]] && return 1
  echo "$blocked_pr"
  return 0
}
