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
