#!/usr/bin/env bash
set -euo pipefail

its::get_issue() {
  local issue_id="$1"
  gh issue view "$issue_id" --repo "$REPO" --json title,body,labels,type,author \
    --jq '{title, body, labels: [.labels[].name], type: (.type.name // ""), author: .author.login}'
}
