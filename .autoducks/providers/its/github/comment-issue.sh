#!/usr/bin/env bash
set -euo pipefail

its::comment_issue() {
  local issue_id="$1"
  local body="$2"
  gh issue comment "$issue_id" --repo "$REPO" --body "$body"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: its::comment_issue ISSUE_ID BODY"; echo "  Post a comment on an issue"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
