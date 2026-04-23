#!/usr/bin/env bash
set -euo pipefail

its::update_issue_body() {
  local issue_id="$1"
  local body_file="$2"
  gh issue edit "$issue_id" --repo "$REPO" --body-file "$body_file"
}
