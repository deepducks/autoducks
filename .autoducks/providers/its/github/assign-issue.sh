#!/usr/bin/env bash
set -euo pipefail

its::assign_issue() {
  local issue_id="$1"
  local assignee="$2"
  [[ -z "$assignee" ]] && return 0
  gh issue edit "$issue_id" --repo "$REPO" --add-assignee "$assignee"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: its::assign_issue ISSUE_ID ASSIGNEE"; echo "  Add an assignee to an issue"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
