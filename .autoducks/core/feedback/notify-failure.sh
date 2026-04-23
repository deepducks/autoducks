#!/usr/bin/env bash
set -euo pipefail

# Notify about a failure on a task issue and optionally on the parent feature issue
# Usage: notify_failure <issue_id> <run_id> [feature_issue_id]
notify_failure() {
  local issue_id="$1"
  local run_id="$2"
  local feature_issue_id="${3:-}"
  local repo="${REPO:?REPO env var required}"

  local body="⚠️ **Agent failed**

The agent run encountered an error.
[View run logs](https://github.com/$repo/actions/runs/$run_id)

Please review the failure and consider using \`/agents fix\` to retry."

  its::comment_issue "$issue_id" "$body" || true

  if [[ -n "$feature_issue_id" ]]; then
    local feature_body="⚠️ **Task #$issue_id failed**

The agent working on task #$issue_id encountered an error.
[View run logs](https://github.com/$repo/actions/runs/$run_id)

The orchestrator will not advance until this task is resolved."
    its::comment_issue "$feature_issue_id" "$feature_body" || true
  fi
}
