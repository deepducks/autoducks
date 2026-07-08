#!/usr/bin/env bash
set -euo pipefail

git::get_pr_diff() {
  local pr_number="$1"
  gh pr diff "$pr_number" --repo "$REPO"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: git::get_pr_diff PR_NUMBER"; echo "  Fetch the unified diff for a pull request"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
