#!/usr/bin/env bash
set -euo pipefail

# Notify that an auto-triggered run was skipped (not failed) because the PR
# modifies autoducks agent workflow files, which claude-code-action refuses to
# run against repository secrets as an anti-tampering safeguard.
# Usage: notify_skip <issue_id> [reason]
notify_skip() {
  local issue_id="$1"
  local reason="${2:-}"
  local repo="${REPO:?REPO env var required}"

  local body
  if [[ -n "$reason" ]]; then
    body="ℹ️ **Skipped.** $reason This is expected, not a failure."
  else
    body="ℹ️ **Auto-review skipped.** This PR modifies autoducks agent workflow files, so \`claude-code-action\` refuses to run the auto-triggered review against repository secrets (an anti-tampering safeguard). This is expected, not a failure.

**Next:** push your changes and run \`$(autoducks_command_for review)\` manually (comment-triggered runs are not subject to this validation), or merge the PR first — the auto-review will work again once the workflow changes land on the default branch."
  fi

  its::comment_issue "$issue_id" "$body" || true
}
