#!/usr/bin/env bash
set -euo pipefail

# Update checkboxes in a feature issue body for completed tasks
# Usage: update_checkboxes <feature_issue_id> <done_task_numbers...>
# done_task_numbers is a space-separated list of completed task issue numbers
update_checkboxes() {
  local feature_issue_id="$1"
  shift
  local done_tasks=("$@")

  [[ ${#done_tasks[@]} -eq 0 ]] && return 0

  local body
  body=$(its::get_issue "$feature_issue_id" | jq -r '.body')

  local updated_body="$body"
  local changed=false

  for t in "${done_tasks[@]}"; do
    local new_body
    new_body=$(echo "$updated_body" | perl -pe "s/^- \\[ \\] #${t}(?!\\d)/- [x] #${t}/gm")
    if [[ "$new_body" != "$updated_body" ]]; then
      updated_body="$new_body"
      changed=true
    fi
  done

  if [[ "$changed" == "true" ]]; then
    local tmpfile
    tmpfile=$(mktemp)
    echo "$updated_body" > "$tmpfile"
    its::update_issue_body "$feature_issue_id" "$tmpfile"
    rm -f "$tmpfile"
  fi
}
