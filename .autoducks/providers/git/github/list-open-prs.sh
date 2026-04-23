#!/usr/bin/env bash
set -euo pipefail

git::list_open_prs() {
  local base="${1:-}"
  local args=(--repo "$REPO" --state open --json number,title,headRefName,body --limit 100)
  [[ -n "$base" ]] && args+=(--base "$base")
  gh pr list "${args[@]}"
}
