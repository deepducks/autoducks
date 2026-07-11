#!/usr/bin/env bash
set -euo pipefail

git::commits_ahead() {
  local base_branch="$1"
  git fetch origin "$base_branch" >/dev/null 2>&1 || true
  git rev-list --count "origin/$base_branch..HEAD"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: git::commits_ahead BASE_BRANCH"; echo "  Print the number of commits HEAD is ahead of origin/BASE_BRANCH"; exit 0 ;;
  esac
fi
