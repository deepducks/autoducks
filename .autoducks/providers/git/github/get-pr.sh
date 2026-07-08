#!/usr/bin/env bash
set -euo pipefail

git::get_pr() {
  local pr_number="$1"
  gh pr view "$pr_number" --repo "$REPO" \
    --json number,title,body,state,isDraft,headRefName,baseRefName,mergeable,mergeStateStatus
}

git::pr_mergeable() {
  git::get_pr "$1" | jq -r '.mergeable'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: git::get_pr PR_NUMBER"; echo "  Fetch a single pull request (JSON)"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
