#!/usr/bin/env bash
set -euo pipefail

git::mark_pr_ready() {
  local pr_number="$1"
  gh pr ready "$pr_number" --repo "$REPO"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: git::mark_pr_ready PR_NUMBER"; echo "  Promote a draft pull request to ready-for-review"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
