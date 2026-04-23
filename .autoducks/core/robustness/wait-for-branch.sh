#!/usr/bin/env bash
set -euo pipefail

# Wait for a branch to become visible on the remote
# Usage: wait_for_branch <branch_name> [max_attempts] [sleep_seconds]
wait_for_branch() {
  local branch_name="$1"
  local max_attempts="${2:-10}"
  local sleep_seconds="${3:-2}"

  for ((i=1; i<=max_attempts; i++)); do
    if git::branch_exists "$branch_name"; then
      return 0
    fi
    echo "Waiting for branch '$branch_name' to appear (attempt $i/$max_attempts)..."
    sleep "$sleep_seconds"
  done

  echo "::error::Branch '$branch_name' not visible after $max_attempts attempts"
  return 1
}
