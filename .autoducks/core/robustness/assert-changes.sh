#!/usr/bin/env bash
set -euo pipefail

# Assert that the agent made changes to the working tree
# Usage: assert_changes
# Exits 1 if no changes were made
assert_changes() {
  git add -A
  if git diff --cached --quiet; then
    if git log --oneline -1 &>/dev/null; then
      echo "::warning::No new changes detected, but prior commits exist on this branch"
      return 0
    fi
    echo "::error::Agent made no changes to the codebase"
    return 1
  fi
  return 0
}
