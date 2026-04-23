#!/usr/bin/env bash
set -euo pipefail

git::delete_branch() {
  local name="$1"
  gh api "repos/$REPO/git/refs/heads/$name" --method DELETE --silent 2>/dev/null || true
}
