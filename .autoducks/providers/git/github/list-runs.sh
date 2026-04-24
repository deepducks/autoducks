#!/usr/bin/env bash
set -euo pipefail

git::list_runs() {
  local workflow="$1"
  local status="${2:-}"
  local args=(--repo "$REPO" --workflow="$workflow" --json databaseId,createdAt,status,conclusion --limit 10)
  [[ -n "$status" ]] && args+=(--status "$status")
  gh run list "${args[@]}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: git::list_runs WORKFLOW [STATUS]"; echo "  List recent workflow runs (JSON)"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
