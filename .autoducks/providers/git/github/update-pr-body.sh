#!/usr/bin/env bash
set -euo pipefail

git::update_pr_body() {
  local pr_number="$1"
  local body="$2"
  gh pr edit "$pr_number" --repo "$REPO" --body "$body"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: git::update_pr_body PR_NUMBER BODY"; echo "  Rewrite a pull request's body in place"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
