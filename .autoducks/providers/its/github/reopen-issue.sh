#!/usr/bin/env bash
set -euo pipefail

its::reopen_issue() {
  local issue_id="$1"
  local comment="${2:-}"
  local args=(--repo "$REPO")
  [[ -n "$comment" ]] && args+=(--comment "$comment")
  gh issue reopen "$issue_id" "${args[@]}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: its::reopen_issue ISSUE_ID [COMMENT]"; echo "  Reopen a closed issue, optionally with a comment"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
