#!/usr/bin/env bash
set -euo pipefail

RECONCILE_TASKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../config/label-utils.sh
source "$RECONCILE_TASKS_DIR/../config/label-utils.sh"

# Reconcile tasks from a parsed plan with existing tasks
# Usage: reconcile_tasks <feature_issue_id> <tasks_jsonl_file> <existing_task_numbers_space_separated>
# Returns: space-separated list of final task numbers (in order)
reconcile_tasks() {
  local feature_issue_id="$1"
  local tasks_file="$2"
  local existing_numbers="${3:-}"

  local -a old_numbers=()
  [[ -n "$existing_numbers" ]] && read -ra old_numbers <<< "$existing_numbers"

  local -a new_numbers=()
  local -A placeholder_map=()

  : > /tmp/link-outcomes.tsv

  # Ensure Task label exists — color/desc must match scripts/setup.sh
  label::ensure "Task" "1D76DB" "Autoducks task issue" 2>/dev/null || true

  while IFS= read -r line; do
    local ref title body labels
    ref=$(echo "$line" | jq -r '.ref')
    title=$(echo "$line" | jq -r '.title')
    body=$(echo "$line" | jq -r '.body')
    labels=$(echo "$line" | jq -r '.labels | join(",")')

    if [[ "$ref" =~ ^[0-9]+$ ]]; then
      # Preserved task: update title/body if changed
      local current
      current=$(its::get_issue "$ref" | jq -r '.title + "" + .body')
      local current_title="${current%%$'\x01'*}"
      local current_body="${current#*$'\x01'}"

      if [[ "$title" != "$current_title" || "$body" != "$current_body" ]]; then
        local tmpfile
        tmpfile=$(mktemp)
        echo "$body" > "$tmpfile"
        gh issue edit "$ref" --repo "$REPO" --title "$title" --body-file "$tmpfile" 2>/dev/null || true
        rm -f "$tmpfile"
      fi
      new_numbers+=("$ref")
      local ref_db_id
      ref_db_id=$(gh api "repos/$REPO/issues/$ref" --jq '.id')
      local link_result
      link_result=$(its::link_sub_issue "$feature_issue_id" "$ref_db_id")
      printf '%s\t%s\n' "$ref" "$link_result" >> /tmp/link-outcomes.tsv
    else
      # New task (Tn placeholder): create issue
      local labels_with_task
      if [[ -n "$labels" ]]; then
        labels_with_task="${labels},Task"
      else
        labels_with_task="Task"
      fi

      local create_payload
      create_payload=$(jq -n \
        --arg title "$title" \
        --arg body "$body" \
        --argjson labels "$(echo "$labels_with_task" | jq -R 'split(",")')" \
        '{title: $title, body: $body, labels: $labels}')

      local create_response
      create_response=$(gh api "repos/$REPO/issues" --method POST --input - <<< "$create_payload")
      local task_id task_db_id
      task_id=$(echo "$create_response" | jq -r '.number')
      task_db_id=$(echo "$create_response" | jq -r '.id')

      # Best-effort native issue type (silently no-ops when the org doesn't have a `Task` type)
      its::set_issue_type "$task_id" "Task" 2>/dev/null || true

      local link_result
      link_result=$(its::link_sub_issue "$feature_issue_id" "$task_db_id")
      printf '%s\t%s\n' "$task_id" "$link_result" >> /tmp/link-outcomes.tsv

      placeholder_map["$ref"]="$task_id"
      new_numbers+=("$task_id")
    fi
  done < "$tasks_file"

  # Close dropped tasks
  for old in "${old_numbers[@]}"; do
    local found=false
    for new in "${new_numbers[@]}"; do
      [[ "$old" == "$new" ]] && { found=true; break; }
    done
    if [[ "$found" == "false" ]]; then
      its::close_issue "$old" "Superseded by revised plan on #$feature_issue_id" "not_planned" || true
    fi
  done

  # Output results
  echo "TASK_NUMBERS=${new_numbers[*]}"
  for ph in "${!placeholder_map[@]}"; do
    echo "PLACEHOLDER|$ph|${placeholder_map[$ph]}"
  done
}
