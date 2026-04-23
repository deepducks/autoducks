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
