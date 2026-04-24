#!/usr/bin/env bash
set -euo pipefail

git::list_open_prs() {
  local base="${1:-}"
  local args=(--repo "$REPO" --state open --json number,title,headRefName,body --limit 100)
  [[ -n "$base" ]] && args+=(--base "$base")
  gh pr list "${args[@]}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: git::list_open_prs [BASE_BRANCH]"; echo "  List open PRs, optionally filtered by base (JSON)"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
