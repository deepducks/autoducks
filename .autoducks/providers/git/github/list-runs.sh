#!/usr/bin/env bash
set -euo pipefail

git::list_runs() {
  local workflow="$1"
  local status="${2:-}"
  local args=(--repo "$REPO" --workflow="$workflow" --json databaseId,createdAt,status,conclusion --limit 10)
  [[ -n "$status" ]] && args+=(--status "$status")
  gh run list "${args[@]}"
}
