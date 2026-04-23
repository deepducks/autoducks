#!/usr/bin/env bash
set -euo pipefail

git::dispatch_workflow() {
  local workflow="$1"
  shift
  # Remaining args are -f key=value pairs
  gh workflow run "$workflow" --repo "$REPO" "$@"
}
