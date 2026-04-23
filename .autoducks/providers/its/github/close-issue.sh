#!/usr/bin/env bash
set -euo pipefail

its::close_issue() {
  local issue_id="$1"
  local comment="${2:-}"
  local args=(--repo "$REPO")
  [[ -n "$comment" ]] && args+=(--comment "$comment")
  gh issue close "$issue_id" "${args[@]}"
}
