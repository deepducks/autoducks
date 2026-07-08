#!/usr/bin/env bash
set -euo pipefail

# Notify about a failure on a task issue and optionally on the parent feature issue.
# Usage: notify_failure <issue_id> <run_id> [feature_issue_id]
#
# Optional context (env, all default to empty/"infra"):
#   AUTODUCKS_AGENT          — set already by every entry script (execution|fix|tactical|design|waveOrchestrator)
#   AUTODUCKS_FAIL_PHASE     — pre | llm | post   (default: "" → omitted from message)
#   AUTODUCKS_FAIL_CATEGORY  — merge-conflict | no-changes | scope-missing | parse | max_turns | infra
#                              (default: "infra")
#   AUTODUCKS_FAIL_BRANCH    — pushed branch with preserved work (max_turns only)
notify_failure() {
  [[ -n "${_AUTODUCKS_NOTIFIED:-}" ]] && return 0
  _AUTODUCKS_NOTIFIED=1

  local issue_id="$1"
  local run_id="$2"
  local feature_issue_id="${3:-}"
  local repo="${REPO:?REPO env var required}"

  local agent="${AUTODUCKS_AGENT:-}"
  local phase="${AUTODUCKS_FAIL_PHASE:-}"
  local category="${AUTODUCKS_FAIL_CATEGORY:-infra}"

  local diagnosis retry
  case "$category" in
    merge-conflict)
      diagnosis="The task PR could not be merged into the feature branch (likely a conflict with work merged by another wave task)."
      retry="\`/agents fix\` on this task"
      ;;
    no-changes)
      diagnosis="The agent finished but produced no code changes."
      retry="\`/agents fix\` (or refine the issue spec and re-run)"
      ;;
    scope-missing)
      diagnosis="The agent did not produce the expected output file (spec / tactical plan)."
      retry="re-run \`/agents design\` or \`/agents devise\`"
      ;;
    parse)
      diagnosis="The tactical plan could not be parsed into tasks."
      retry="re-run \`/agents devise\`"
      ;;
    max_turns)
      diagnosis="The agent hit its turn limit before finishing — **partial work has been preserved** (see the branch below)."
      retry="\`/agents fix\` to resume from the partial branch"
      ;;
    *)
      category="infra"
      diagnosis="The run hit an unexpected error before it could finish (API, git, or runtime issue)."
      retry="\`/agents fix\` to retry"
      ;;
  esac

  local context_line="**Agent:** \`${agent:-unknown}\`"
  [[ -n "$phase" ]] && context_line+="  ·  **Phase:** \`$phase\`"
  context_line+="  ·  **Category:** \`$category\`"

  # max_turns: append the preserved branch name and any work summary the agent
  # left behind, so the next /agents fix knows exactly where to resume.
  local partial_section=""
  if [[ "$category" == "max_turns" ]]; then
    if [[ -n "${AUTODUCKS_FAIL_BRANCH:-}" ]]; then
      partial_section+="

**Preserved branch:** \`${AUTODUCKS_FAIL_BRANCH}\`"
    fi
    if [[ -s /tmp/work-summary.md ]]; then
      partial_section+="

**Work so far:**

$(cat /tmp/work-summary.md)"
    fi
  fi

  local body="⚠️ **Agent run failed.**

$context_line

$diagnosis

📄 [View the run logs](https://github.com/$repo/actions/runs/$run_id) to see
what went wrong.${partial_section}

**Next:** $retry."

  its::comment_issue "$issue_id" "$body" || true

  if [[ -n "$feature_issue_id" ]]; then
    local feature_body="⚠️ **Task #$issue_id failed.**

$context_line

$diagnosis

A task in this feature hit an error, so the wave orchestrator has paused and
will **not** advance until the task is resolved.

📄 [View the run logs](https://github.com/$repo/actions/runs/$run_id).${partial_section}

**Next:** $retry."
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
