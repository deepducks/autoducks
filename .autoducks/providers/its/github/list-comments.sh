#!/usr/bin/env bash
set -euo pipefail

its::list_comments() {
  local issue_id="$1"
  local limit="${2:-}"

  local url="repos/$REPO/issues/$issue_id/comments"
  if [[ -n "$limit" ]]; then
    url="${url}?per_page=${limit}"
  fi

  gh api "$url" --jq '[.[] | {id, author: .user.login, body, created_at, updated_at}]'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: its::list_comments ISSUE_ID [LIMIT]"; echo "  List comments on an issue (JSON)"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
