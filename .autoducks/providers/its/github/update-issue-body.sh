#!/usr/bin/env bash
set -euo pipefail

its::update_issue_body() {
  local issue_id="$1"
  local body_file="$2"
  gh issue edit "$issue_id" --repo "$REPO" --body-file "$body_file"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: its::update_issue_body ISSUE_ID BODY_FILE"; echo "  Update an issue body from a file"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
