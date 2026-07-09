#!/usr/bin/env bash
set -euo pipefail

# Notify that an auto-triggered run was skipped (not failed) because the PR
# modifies autoducks agent workflow files, which claude-code-action refuses to
# run against repository secrets as an anti-tampering safeguard.
#
# The remediation names the *calling agent's* own command, derived from
# AUTODUCKS_AGENT (or an explicit reason override), so a skipped developer run
# points at `/execute`, a skipped architect run at `/architect`, etc.
#
# Usage: notify_skip <issue_id> [reason]
#   reason — optional agent-key override; defaults to AUTODUCKS_AGENT.
notify_skip() {
  local issue_id="$1"
  local agent="${2:-${AUTODUCKS_AGENT:-}}"
  local repo="${REPO:?REPO env var required}"

  local verb heading run_noun
  case "$agent" in
    reviewer) verb="review";    heading="Auto-review skipped.";       run_noun="auto-review" ;;
    architect) verb="architect"; heading="Auto-triggered run skipped."; run_noun="auto-triggered run" ;;
    engineer)  verb="engineer";  heading="Auto-triggered run skipped."; run_noun="auto-triggered run" ;;
    developer) verb="execute";   heading="Auto-triggered run skipped."; run_noun="auto-triggered run" ;;
    fix)       verb="fix";       heading="Auto-triggered run skipped."; run_noun="auto-triggered run" ;;
    defer)     verb="defer";     heading="Auto-triggered run skipped."; run_noun="auto-triggered run" ;;
    rework)    verb="rework";    heading="Auto-triggered run skipped."; run_noun="auto-triggered run" ;;
    resolver)  verb="resolve";   heading="Auto-triggered run skipped."; run_noun="auto-triggered run" ;;
    *)         verb="fix";       heading="Auto-triggered run skipped."; run_noun="auto-triggered run" ;;
  esac

  local cmd; cmd="$(autoducks_command_for "$verb")"
  local body="ℹ️ **${heading}** This PR modifies autoducks agent workflow files, so \`claude-code-action\` refuses to run the auto-triggered run against repository secrets (an anti-tampering safeguard). This is expected, not a failure.

**Next:** push your changes and run \`${cmd}\` manually (comment-triggered runs are not subject to this validation), or merge the PR first — the ${run_noun} will work again once the workflow changes land on the default branch."

  its::comment_issue "$issue_id" "$body" || true
}
