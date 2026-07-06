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

  local pr_num err_file
  err_file=$(mktemp)
  if pr_num=$(git::create_pr "$feature_branch" "$base_branch" "Feature #$feature_issue: $issue_title" "$(echo -e "$closes_body")" 2>"$err_file"); then
    rm -f "$err_file"
    echo "$pr_num"
    return 0
  fi

  if grep -qi 'already exists' "$err_file"; then
    rm -f "$err_file"
    existing_pr=$(gh pr list --repo "$REPO" --head "$feature_branch" --base "$base_branch" --state all --json number --jq '.[0].number // empty' 2>/dev/null || true)
    if [[ -n "$existing_pr" ]]; then
      echo "$existing_pr"
      return 0
    fi
    echo "create_final_pr: 'already exists' reported but no PR found for $feature_branch → $base_branch" >&2
    return 1
  fi

  cat "$err_file" >&2
  rm -f "$err_file"
  return 1
}
