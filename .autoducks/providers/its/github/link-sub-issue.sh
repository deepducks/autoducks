#!/usr/bin/env bash
set -euo pipefail

its::link_sub_issue() {
  local parent_id="$1"
  local child_id="$2"
  gh api "repos/$REPO/issues/$parent_id/sub_issues" --method POST \
    -F "sub_issue_id=$child_id" --silent
}
