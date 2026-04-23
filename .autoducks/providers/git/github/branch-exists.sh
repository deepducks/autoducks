#!/usr/bin/env bash
set -euo pipefail

git::branch_exists() {
  local name="$1"
  gh api "repos/$REPO/git/refs/heads/$name" --silent 2>/dev/null
}
