#!/usr/bin/env bash
set -euo pipefail

its::comment_issue() {
  local issue_id="$1"
  local body="$2"
  # Stamped so revert can recognise it later regardless of which credential
  # posted it (#183). Degrades to an unstamped comment if the marker helper is
  # not loaded, rather than failing the post.
  if declare -F comment_marker::stamp >/dev/null 2>&1; then
    body="$(comment_marker::stamp "$body")"
  fi
  gh issue comment "$issue_id" --repo "$REPO" --body "$body"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: its::comment_issue ISSUE_ID BODY"; echo "  Post a comment on an issue"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
