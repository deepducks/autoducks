#!/usr/bin/env bash
set -euo pipefail

its::link_sub_issue() {
  local parent_id="$1"
  local child_id="$2"
  gh api "repos/$REPO/issues/$parent_id/sub_issues" --method POST \
    -F "sub_issue_id=$child_id" --silent
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: its::link_sub_issue PARENT_ID CHILD_ID"; echo "  Link a child issue as sub-issue of parent"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
