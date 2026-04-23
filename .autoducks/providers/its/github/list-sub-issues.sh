#!/usr/bin/env bash
set -euo pipefail

its::list_sub_issues() {
  local issue_id="$1"
  gh api "repos/$REPO/issues/$issue_id/sub_issues" \
    --jq '[.[] | {number, title, state}]'
}
