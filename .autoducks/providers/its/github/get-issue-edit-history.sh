#!/usr/bin/env bash
set -euo pipefail

its::get_issue_edit_history() {
  local issue_id="$1"

  gh api graphql -f query='
    query($owner: String!, $name: String!, $num: Int!) {
      repository(owner: $owner, name: $name) {
        issue(number: $num) {
          userContentEdits(first: 50) {
            nodes { editor { login } editedAt diff }
          }
        }
      }
    }' -F "owner=${REPO%/*}" -F "name=${REPO#*/}" -F "num=$issue_id"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: its::get_issue_edit_history ISSUE_ID"; echo "  Fetch issue edit history via GraphQL (JSON)"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
