#!/usr/bin/env bash
set -euo pipefail

git::submit_pr_review() {
  local pr_number="$1"
  local event="$2"
  local body_file="$3"
  local flag="${event,,}"
  flag="${flag//_/-}"
  gh pr review "$pr_number" --repo "$REPO" --"${flag}" --body-file "$body_file"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: git::submit_pr_review PR_NUMBER EVENT BODY_FILE"; echo "  Submit a PR review (EVENT: COMMENT|REQUEST_CHANGES|APPROVE)"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
