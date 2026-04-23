#!/usr/bin/env bash
set -euo pipefail

git::find_branches_matching() {
  local pattern="$1"
  gh api "repos/$REPO/git/matching-refs/heads/$pattern" \
    --jq '.[].ref | sub("^refs/heads/"; "")' 2>/dev/null || true
}
