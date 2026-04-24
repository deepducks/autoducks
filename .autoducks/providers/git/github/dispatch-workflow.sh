#!/usr/bin/env bash
set -euo pipefail

git::dispatch_workflow() {
  local workflow="$1"
  shift
  # Remaining args are -f key=value pairs
  gh workflow run "$workflow" --repo "$REPO" "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: git::dispatch_workflow WORKFLOW [ARGS...]"; echo "  Trigger a GitHub Actions workflow dispatch"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
