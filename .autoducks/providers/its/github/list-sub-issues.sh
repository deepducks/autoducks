#!/usr/bin/env bash
set -euo pipefail

its::list_sub_issues() {
  local issue_id="$1"
  gh api "repos/$REPO/issues/$issue_id/sub_issues" \
    --jq '[.[] | {number, title, state}]'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: its::list_sub_issues ISSUE_ID"; echo "  List sub-issues of a parent issue (JSON)"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
