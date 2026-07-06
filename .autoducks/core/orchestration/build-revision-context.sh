#!/usr/bin/env bash
set -euo pipefail

source "$AUTODUCKS_ROOT/core/orchestration/tactical-zone.sh"

# Build revision context for the tactical agent
# Usage: build_revision_context <feature_issue_id> <task_numbers_space_separated> <output_file>
build_revision_context() {
  local feature_issue_id="$1"
  local task_numbers="$2"
  local output_file="$3"

  {
    # Fetch and split the body into zones
    local body_file design_file tactical_file
    body_file=$(mktemp)
    design_file=$(mktemp)
    tactical_file=$(mktemp)
    its::get_issue "$feature_issue_id" | jq -r '.body' > "$body_file"

    if body_has_markers "$body_file"; then
      split_body "$body_file" "$design_file" "$tactical_file"
    else
      # Legacy fallback: entire body is the tactical zone
      : > "$design_file"
      cp "$body_file" "$tactical_file"
    fi

    echo "# Design Zone (READ-ONLY — preserved verbatim in issue body)"
    echo ""
    cat "$design_file"
    echo ""
    echo "---"
    echo ""

    echo "# Current Tactical Zone (the artifact you are revising)"
    echo ""
    cat "$tactical_file"
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

    rm -f "$body_file" "$design_file" "$tactical_file"
  } > "$output_file"
}
