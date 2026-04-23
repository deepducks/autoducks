#!/usr/bin/env bash
set -euo pipefail

git::close_pr() {
  local pr_number="$1"
  local comment="${2:-}"
  local args=(--repo "$REPO")
  [[ -n "$comment" ]] && args+=(--comment "$comment")
  gh pr close "$pr_number" "${args[@]}"
}
