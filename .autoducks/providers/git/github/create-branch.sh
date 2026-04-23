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
