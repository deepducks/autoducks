#!/usr/bin/env bash
set -euo pipefail

# ── Branch prefix by issue type (D10) ────────────────────────────────
# Feature issues get `feature/…` branches; Bug issues get `fix/…` branches.
# Task branches inherit the prefix of the parent (feature/bug) branch they
# are cut from. Note: the fix *utility* agent's `-fix-<epoch>` suffix is a
# different, unrelated naming convention.

# branch_prefix_for_issue ISSUE_NUM → "fix" | "feature"
# Decides by native issue type first, then by label.
branch_prefix_for_issue() {
  local issue_id="$1"
  local data type labels
  data=$(its::get_issue "$issue_id")
  type=$(echo "$data" | jq -r '.type // empty')
  labels=$(echo "$data" | jq -r '.labels[]? // empty')
  if [[ "$type" == "Bug" ]] || echo "$labels" | grep -qx 'Bug'; then
    echo "fix"
  else
    echo "feature"
  fi
}

# branch_prefix_of BRANCH → "feature" | "fix"
# Extracts the pipeline prefix of an existing branch name; defaults to
# "feature" for anything unrecognized (e.g. the repo default branch).
branch_prefix_of() {
  local branch="$1"
  case "$branch" in
    fix/*)     echo "fix" ;;
    feature/*) echo "feature" ;;
    *)         echo "feature" ;;
  esac
}

# pipeline_branch_number BRANCH → the parent issue number encoded in a
# pipeline branch name (`feature/<N>-…` or `fix/<N>-…`), or empty.
pipeline_branch_number() {
  local branch="$1"
  if [[ "$branch" =~ ^(feature|fix)/([0-9]+) ]]; then
    echo "${BASH_REMATCH[2]}"
  fi
}
