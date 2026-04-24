#!/usr/bin/env bash
set -euo pipefail

git::list_merged_prs() {
  local base="$1"
  gh pr list --repo "$REPO" --state merged --base "$base" \
    --json number,title,body --limit 100
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: git::list_merged_prs BASE_BRANCH"; echo "  List merged PRs targeting a base branch (JSON)"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
