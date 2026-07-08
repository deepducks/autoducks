#!/usr/bin/env bash
set -euo pipefail

git::mark_pr_draft() {
  local pr_number="$1"
  gh pr ready "$pr_number" --repo "$REPO" --undo
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: git::mark_pr_draft PR_NUMBER"; echo "  Convert a ready pull request back to draft"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
