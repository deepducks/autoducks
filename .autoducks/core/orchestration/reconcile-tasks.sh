#!/usr/bin/env bash
set -euo pipefail

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

  # Ensure priority labels exist
  for p in P0 P1 P2 P3; do
    gh label create "priority:$p" --repo "$REPO" 2>/dev/null || true
  done

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
    else
      # New task (Tn placeholder): create issue
      local create_payload
      create_payload=$(jq -n \
        --arg title "$title" \
        --arg body "$body" \
        --argjson labels "$(echo "$labels" | jq -R 'split(",")')" \
        '{title: $title, body: $body, labels: $labels}')

      local task_id
      task_id=$(gh api "repos/$REPO/issues" --method POST --input - <<< "$create_payload" | jq -r '.number')

      its::link_sub_issue "$feature_issue_id" "$task_id" 2>/dev/null || true

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
      its::close_issue "$old" "Superseded by revised plan on #$feature_issue_id" 2>/dev/null || true
    fi
  done

  # Output results
  echo "TASK_NUMBERS=${new_numbers[*]}"
  for ph in "${!placeholder_map[@]}"; do
    echo "PLACEHOLDER|$ph|${placeholder_map[$ph]}"
  done
}
