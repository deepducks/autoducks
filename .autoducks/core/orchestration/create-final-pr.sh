#!/usr/bin/env bash
set -euo pipefail

create_final_pr() {
  local feature_issue="$1"
  local feature_branch="$2"
  local base_branch="$3"
  local issue_title="$4"
  local delivered_children="$5"
  shift 5
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

  local delivered_marker
  delivered_marker="$(metarepo::delivered_children_marker "$delivered_children")"
  if [[ -n "$delivered_marker" ]]; then
    closes_body+="\n\n$delivered_marker"
  fi

  # git::create_pr already recovers its own "already exists"/read:org errors
  # by searching for an *open* PR (git::_find_open_pr_number); it only
  # surfaces a failure here if that open-state search comes up empty. This
  # fallback is not a double-wrap of the same error — it re-checks with
  # `--state all` to catch the case where the existing PR isn't open
  # (e.g. already merged/closed), which git::create_pr's narrower open-state
  # lookup can't find. A genuine (non-"already exists") failure still falls
  # through to the final `cat "$err_file" >&2; return 1` below undisturbed.
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
