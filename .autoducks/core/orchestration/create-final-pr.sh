#!/usr/bin/env bash
set -euo pipefail

create_final_pr() {
  local feature_issue="$1"
  local feature_branch="$2"
  local base_branch="$3"
  local issue_title="$4"
  shift 4
  local wave_tasks=("$@")

  local existing_pr
  existing_pr=$(gh pr list --repo "$REPO" --head "$feature_branch" --base "$base_branch" --state all --json number --jq '.[0].number // empty' 2>/dev/null || true)

  if [[ -n "$existing_pr" ]]; then
    echo "$existing_pr"
    return 0
  fi

  local closes_body=""
  for t in "${wave_tasks[@]}"; do
    [[ -z "$t" ]] && continue
    closes_body+="Closes #$t\n"
  done
  closes_body+="Closes #$feature_issue"

  git::create_pr "$feature_branch" "$base_branch" "Feature #$feature_issue: $issue_title" "$(echo -e "$closes_body")"
}
