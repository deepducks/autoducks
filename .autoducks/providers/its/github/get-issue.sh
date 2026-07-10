#!/usr/bin/env bash
set -euo pipefail

its::get_issue() {
  local issue_id="$1"
  local base type
  base=$(gh issue view "$issue_id" --repo "$REPO" --json title,body,labels,author \
    --jq '{title, body, labels: [.labels[].name], author: .author.login}')
  # Native issue type is org-only; absent on user repos / untyped issues → empty.
  type=$(gh api "repos/$REPO/issues/$issue_id" --jq '.type.name // ""' 2>/dev/null || echo "")
  jq -n --argjson base "$base" --arg type "$type" '$base + {type: (if $type == "" then null else $type end)}'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: its::get_issue ISSUE_ID"; echo "  Fetch issue details: title, body, labels, type, author (JSON)"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
