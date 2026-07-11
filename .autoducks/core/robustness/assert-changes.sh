#!/usr/bin/env bash
set -euo pipefail

# Assert that the agent made changes to the working tree
# Usage: assert_changes <base_branch>
# Exits 1 if no changes were made
assert_changes() {
  local base="$1"
  git add -A
  if git diff --cached --quiet; then
    if [[ "$(git::commits_ahead "$base")" -gt 0 ]]; then
      echo "::warning::No newly-staged changes, but this branch is ahead of base"
      return 0
    fi
    echo "::error::Agent made no changes to the codebase"
    return 1
  fi
  return 0
}
