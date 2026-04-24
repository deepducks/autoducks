#!/usr/bin/env bash
set -euo pipefail

git::close_pr() {
  local pr_number="$1"
  local comment="${2:-}"
  local args=(--repo "$REPO")
  [[ -n "$comment" ]] && args+=(--comment "$comment")
  gh pr close "$pr_number" "${args[@]}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: git::close_pr PR_NUMBER [COMMENT]"; echo "  Close a pull request, optionally with a comment"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
