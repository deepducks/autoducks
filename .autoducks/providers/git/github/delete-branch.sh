#!/usr/bin/env bash
set -euo pipefail

git::delete_branch() {
  local name="$1"
  gh api "repos/$REPO/git/refs/heads/$name" --method DELETE --silent 2>/dev/null || true
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: git::delete_branch BRANCH_NAME"; echo "  Delete a remote branch"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
