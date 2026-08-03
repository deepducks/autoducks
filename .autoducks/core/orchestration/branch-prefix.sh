#!/usr/bin/env bash
set -euo pipefail

BRANCH_PREFIX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../config/label-utils.sh
source "$BRANCH_PREFIX_DIR/../config/label-utils.sh"

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
  type="${type#"${type%%[![:space:]]*}"}"
  type="${type%"${type##*[![:space:]]}"}"
  labels=$(echo "$data" | jq -r '.labels[]? // empty')
  if [[ "${type,,}" == "bug" ]] || label::in_list "$labels" Bug; then
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

# resolve_feature_num_from_pr HEAD_REF PR_BODY → feature/bug issue number, or empty
# Authoritative source is the pipeline branch name (feature/<N>-… | fix/<N>-…).
# Falls back to the PR body's `Closes #N` refs — preferring the LAST ref, since
# the Maestro appends `Closes #<feature>` after every `Closes #<task>`
# (agents/maestro/run.sh; core/orchestration/create-final-pr.sh).
resolve_feature_num_from_pr() {
  local head_ref="$1" pr_body="${2:-}"
  local n
  n=$(pipeline_branch_number "$head_ref")
  if [[ -n "$n" ]]; then
    echo "$n"
    return 0
  fi
  # Non-pipeline head: take the LAST `Closes #N` (feature is appended last).
  sed -nE 's/.*(^|[^[:alnum:]_])[Cc]loses[[:space:]]+#([0-9]+).*/\2/p' <<< "$pr_body" | tail -1 || true
}
