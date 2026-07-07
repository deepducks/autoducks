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

# Notify that an agent finished but its PR could not be auto-merged because of a
# merge/rebase conflict. References the offending branch and PR so the human can
# act on it directly.
# Usage: notify_conflict <issue_id> <run_id> <branch> <pr_number> [feature_issue_id]
notify_conflict() {
  local issue_id="$1"
  local run_id="$2"
  local branch="$3"
  local pr_number="$4"
  local feature_issue_id="${5:-}"
  local repo="${REPO:?REPO env var required}"

  local body="🔀 **Merge conflict — could not auto-merge.**

The agent finished its work, but PR #${pr_number} (branch \`${branch}\`) has a
**merge conflict** with its target branch and could not be merged automatically.

📄 [View the run logs](https://github.com/$repo/actions/runs/$run_id) for details.

**Next:** resolve the conflict on PR #${pr_number} (rebase or merge the target
branch into \`${branch}\` and fix the conflicting files), then comment
\`/agents fix\` to retry."

  its::comment_issue "$issue_id" "$body" || true

  if [[ -n "$feature_issue_id" ]]; then
    local feature_body="🔀 **Task #$issue_id hit a merge conflict.**

PR #${pr_number} (branch \`${branch}\`) conflicts with the feature branch, so the
wave orchestrator has paused and will **not** advance until it is resolved.

📄 [View the run logs](https://github.com/$repo/actions/runs/$run_id).

**Next:** resolve the conflict on PR #${pr_number}, then comment \`/agents fix\`
on task #$issue_id; the orchestrator resumes automatically once its PR merges."
    its::comment_issue "$feature_issue_id" "$feature_body" || true
  fi
}
