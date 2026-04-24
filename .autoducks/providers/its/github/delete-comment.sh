#!/usr/bin/env bash
set -euo pipefail

its::delete_comment() {
  local comment_id="$1"
  gh api "repos/$REPO/issues/comments/$comment_id" --method DELETE --silent || return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: its::delete_comment COMMENT_ID"; echo "  Delete a comment by ID"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
