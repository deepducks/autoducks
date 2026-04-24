#!/usr/bin/env bash
set -euo pipefail

git::branch_exists() {
  local name="$1"
  gh api "repos/$REPO/git/refs/heads/$name" --silent 2>/dev/null
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: git::branch_exists BRANCH_NAME"; echo "  Check if a remote branch exists (exit 0 if yes)"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
