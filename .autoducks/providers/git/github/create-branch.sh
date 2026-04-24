#!/usr/bin/env bash
set -euo pipefail

git::create_branch() {
  local base="$1"
  local name="$2"
  local sha
  sha=$(gh api "repos/$REPO/git/refs/heads/$base" --jq '.object.sha')
  gh api "repos/$REPO/git/refs" -X POST \
    -f "ref=refs/heads/$name" \
    -f "sha=$sha" --silent
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: git::create_branch BASE_BRANCH BRANCH_NAME"; echo "  Create a new remote branch from base"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
