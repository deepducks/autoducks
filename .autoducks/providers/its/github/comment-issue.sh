#!/usr/bin/env bash
set -euo pipefail

its::comment_issue() {
  local issue_id="$1"
  local body="$2"
  gh issue comment "$issue_id" --repo "$REPO" --body "$body"
}
