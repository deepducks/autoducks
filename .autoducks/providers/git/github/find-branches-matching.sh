#!/usr/bin/env bash
set -euo pipefail

git::find_branches_matching() {
  local pattern="$1"
  gh api "repos/$REPO/git/matching-refs/heads/$pattern" \
    --jq '.[].ref | sub("^refs/heads/"; "")' 2>/dev/null || true
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: git::find_branches_matching PATTERN"; echo "  List remote branches matching a ref pattern"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
