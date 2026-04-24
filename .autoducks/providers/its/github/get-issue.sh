#!/usr/bin/env bash
set -euo pipefail

its::get_issue() {
  local issue_id="$1"
  gh issue view "$issue_id" --repo "$REPO" --json title,body,labels,author \
    --jq '{title, body, labels: [.labels[].name], author: .author.login}'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: its::get_issue ISSUE_ID"; echo "  Fetch issue details: title, body, labels, author (JSON)"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
