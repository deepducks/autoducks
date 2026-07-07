#!/usr/bin/env bash
set -euo pipefail

# Notify about a failure on a task issue and optionally on the parent feature issue
# Usage: notify_failure <issue_id> <run_id> [feature_issue_id]
notify_failure() {
  local issue_id="$1"
  local run_id="$2"
  local feature_issue_id="${3:-}"
  local repo="${REPO:?REPO env var required}"

  local body="⚠️ **Agent run failed.**

The run hit an error before it could finish. The most common causes are a
merge conflict, a failing check, or the agent producing no changes.

📄 [View the run logs](https://github.com/$repo/actions/runs/$run_id) to see
what went wrong.

**Next:** address the issue if it's on your side, then comment \`/agents fix\`
to retry from where the run left off."

  its::comment_issue "$issue_id" "$body" || true

  if [[ -n "$feature_issue_id" ]]; then
    local feature_body="⚠️ **Task #$issue_id failed.**

A task in this feature hit an error, so the wave orchestrator has paused and
will **not** advance until the task is resolved.

📄 [View the run logs](https://github.com/$repo/actions/runs/$run_id).

**Next:** comment \`/agents fix\` on task #$issue_id to retry; the orchestrator
resumes automatically once its PR merges."
    its::comment_issue "$feature_issue_id" "$feature_body" || true
  fi
}
