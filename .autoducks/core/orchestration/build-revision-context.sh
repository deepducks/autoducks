#!/usr/bin/env bash
set -euo pipefail

# Build revision context for the tactical agent
# Usage: build_revision_context <feature_issue_id> <task_numbers_space_separated> <output_file>
build_revision_context() {
  local feature_issue_id="$1"
  local task_numbers="$2"
  local output_file="$3"

  {
    echo "# Current Plan"
    echo ""
    its::get_issue "$feature_issue_id" | jq -r '.body'
    echo ""
    echo "---"
    echo ""

    echo "# Existing Tasks"
    echo ""
    local -a nums
    read -ra nums <<< "$task_numbers"
    for num in "${nums[@]}"; do
      local issue_data
      issue_data=$(its::get_issue "$num" 2>/dev/null || echo '{}')
      local title body
      title=$(echo "$issue_data" | jq -r '.title // "Unknown"')
      body=$(echo "$issue_data" | jq -r '.body // ""')
      echo "## Task #$num: $title"
      echo ""
      echo "$body"
      echo ""
      echo "---"
      echo ""
    done

    echo "# Recent Comments"
    echo ""
    its::list_comments "$feature_issue_id" 20 | jq -r '.[] | "### " + .author + "\n\n" + .body + "\n\n---\n"'
  } > "$output_file"
}
