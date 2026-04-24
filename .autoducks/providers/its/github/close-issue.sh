#!/usr/bin/env bash
set -euo pipefail

its::close_issue() {
  local issue_id="$1"
  local comment="${2:-}"
  local args=(--repo "$REPO")
  [[ -n "$comment" ]] && args+=(--comment "$comment")
  gh issue close "$issue_id" "${args[@]}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: its::close_issue ISSUE_ID [COMMENT]"; echo "  Close an issue, optionally with a comment"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
