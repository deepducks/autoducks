#!/usr/bin/env bash
set -euo pipefail

NOTIFY_FAILURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./failure-reported.sh
source "$NOTIFY_FAILURE_DIR/failure-reported.sh"

# Notify about a failure on a task issue and optionally on the parent feature issue.
# Usage: notify_failure <issue_id> <run_id> [feature_issue_id]
#
# Optional context (env, all default to empty/"infra"):
#   AUTODUCKS_AGENT          — set already by every entry script (architect|engineer|maestro|developer|fix|revert|close)
#   AUTODUCKS_FAIL_PHASE     — pre | llm | post   (default: "" → omitted from message)
#   AUTODUCKS_FAIL_CATEGORY  — merge-conflict | no-changes | scope-missing | parse | max_turns | check_failed | infra
#                              (default: "infra")
#   AUTODUCKS_FAIL_BRANCH    — pushed branch with preserved work (max_turns, check_failed)
#   MAX_TURNS                — turn budget the failed run used; sizes the
#                              suggested `turns=<n>` retry hint (max_turns only)
#   AUTODUCKS_CHECKS_MAX_ITERATIONS — number of check-fix iterations attempted
#                              before giving up (check_failed only)
#   AUTODUCKS_AGENT_NAME      — the repo-supplied custom agent's own name
#                              (scope-missing, agent only)
#   AUTODUCKS_AGENT_SOURCE    — path to the custom agent's definition file
#                              (scope-missing, agent only)

# Suggested `turns=<n>` for a max_turns retry: double the budget the failed run
# used, capped at the parser's ceiling (1000). Falls back to the provider
# default (50, see providers/llm/claude/action.yml) when MAX_TURNS is unset or
# malformed, so the hint is always a concrete, in-range integer.
_max_turns_retry_budget() {
  local cur="${MAX_TURNS:-}"
  [[ "$cur" =~ ^[0-9]+$ ]] && (( cur >= 1 && cur <= 1000 )) || cur=50
  local suggested=$(( cur * 2 ))
  if (( suggested > 1000 )); then suggested=1000; fi
  printf '%s' "$suggested"
}

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
      retry="\`$(autoducks_command_for fix)\` on this task"
      ;;
    no-changes)
      diagnosis="The agent finished but produced no code changes."
      retry="\`$(autoducks_command_for fix)\` (or refine the issue spec and re-run)"
      ;;
    scope-missing)
      case "$agent" in
        architect)
          diagnosis="The agent did not produce the expected design spec."
          retry="re-run \`$(autoducks_command_for architect)\`"
          ;;
        engineer)
          diagnosis="The agent did not produce the expected tactical plan."
          retry="re-run \`$(autoducks_command_for engineer)\`"
          ;;
        reviewer)
          diagnosis="The agent did not produce the expected review."
          retry="re-run \`$(autoducks_command_for review)\`"
          ;;
        defer)
          diagnosis="The agent did not produce the expected follow-up issue."
          retry="re-run \`$(autoducks_command_for defer)\`"
          ;;
        rework)
          diagnosis="The agent did not produce the expected rework task."
          retry="re-run \`$(autoducks_command_for rework)\`"
          ;;
        agent)
          diagnosis="The custom agent finished without writing \`/tmp/agent-response.md\`; the definition at \`${AUTODUCKS_AGENT_SOURCE:-<unknown source>}\` may not state an output contract."
          retry="re-run \`$(autoducks_command_for agent) ${AUTODUCKS_AGENT_NAME:-<name>}\`"
          ;;
        *)
          diagnosis="The agent did not produce the expected output file."
          retry="re-run \`$(autoducks_command_for fix)\`"
          ;;
      esac
      ;;
    parse)
      diagnosis="The tactical plan could not be parsed into tasks."
      retry="re-run \`$(autoducks_command_for engineer)\`"
      ;;
    max_turns)
      if [[ -n "${AUTODUCKS_FAIL_BRANCH:-}" ]]; then
        diagnosis="The agent hit its turn limit before finishing — **partial work has been preserved** (see the branch below)."
      else
        diagnosis="The agent hit its turn limit before producing its output — nothing was committed, so re-run with a larger turn budget."
      fi
      local turns; turns=$(_max_turns_retry_budget)
      case "$agent" in
        architect) retry="re-run \`$(autoducks_command_for architect) turns=$turns\`" ;;
        engineer)  retry="re-run \`$(autoducks_command_for engineer) turns=$turns\`" ;;
        reviewer)  retry="re-run \`$(autoducks_command_for review) turns=$turns\`" ;;
        rework)    retry="re-run \`$(autoducks_command_for rework) turns=$turns\`" ;;
        defer)     retry="re-run \`$(autoducks_command_for defer) turns=$turns\`" ;;
        *)         retry="\`$(autoducks_command_for execute) turns=$turns\` to resume from the partial branch with more turns" ;;
      esac
      ;;
    check_failed)
      diagnosis="Automated checks did not pass after ${AUTODUCKS_CHECKS_MAX_ITERATIONS:-N} iterations — the partial work has been preserved (see the branch below)."
      retry="\`$(autoducks_command_for fix)\` on this task to resume from the preserved branch"
      ;;
    *)
      category="infra"
      diagnosis="The run hit an unexpected error before it could finish (API, git, or runtime issue)."
      retry="\`$(autoducks_command_for fix)\` to retry"
      ;;
  esac

  local context_line="**Agent:** \`${agent:-unknown}\`"
  [[ -n "$phase" ]] && context_line+="  ·  **Phase:** \`$phase\`"
  context_line+="  ·  **Category:** \`$category\`"

  # max_turns/check_failed: append the preserved branch name and any work
  # summary the agent left behind, so the next fix run knows exactly where to
  # resume.
  local partial_section=""
  if [[ "$category" == "max_turns" || "$category" == "check_failed" ]]; then
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
  feedback::mark_reported   # the watchdog must stay quiet now (#117)

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
\`$(autoducks_command_for fix)\` to retry."

  its::comment_issue "$issue_id" "$body" || true
  feedback::mark_reported   # the watchdog must stay quiet now (#117)

  if [[ -n "$feature_issue_id" ]]; then
    local feature_body="🔀 **Task #$issue_id hit a merge conflict.**

PR #${pr_number} (branch \`${branch}\`) conflicts with the feature branch, so the
wave orchestrator has paused and will **not** advance until it is resolved.

📄 [View the run logs](https://github.com/$repo/actions/runs/$run_id).

**Next:** resolve the conflict on PR #${pr_number}, then comment \`$(autoducks_command_for fix)\`
on task #$issue_id; the orchestrator resumes automatically once its PR merges."
    its::comment_issue "$feature_issue_id" "$feature_body" || true
  fi
}
