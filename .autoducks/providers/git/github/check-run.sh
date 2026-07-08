#!/usr/bin/env bash
set -euo pipefail

# GitHub Checks API primitives. Used by the reviewer agent to expose its
# verdict as a first-class Check-run so it can gate merges via branch
# protection / rulesets. Requires `checks: write` on the token (GH_TOKEN).

# git::start_check_run NAME HEAD_SHA → echoes the new check-run id.
# Creates an in-progress check attached to the given commit.
git::start_check_run() {
  local name="$1"
  local head_sha="$2"
  jq -n --arg name "$name" --arg sha "$head_sha" \
    '{name: $name, head_sha: $sha, status: "in_progress"}' \
  | gh api "repos/$REPO/check-runs" \
      --method POST \
      -H "Accept: application/vnd.github+json" \
      --input - --jq '.id'
}

# git::conclude_check_run ID CONCLUSION TITLE SUMMARY
# Completes an existing check-run. CONCLUSION ∈
# success|failure|neutral|cancelled|timed_out|action_required.
git::conclude_check_run() {
  local check_run_id="$1"
  local conclusion="$2"
  local title="$3"
  local summary="$4"
  jq -n --arg c "$conclusion" --arg t "$title" --arg s "$summary" \
    '{status: "completed", conclusion: $c, output: {title: $t, summary: $s}}' \
  | gh api "repos/$REPO/check-runs/$check_run_id" \
      --method PATCH \
      -H "Accept: application/vnd.github+json" \
      --input - --jq '.id' >/dev/null
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help)
      echo "Usage:"
      echo "  git::start_check_run NAME HEAD_SHA           → echoes check-run id (status=in_progress)"
      echo "  git::conclude_check_run ID CONCLUSION TITLE SUMMARY"
      echo "  CONCLUSION ∈ success|failure|neutral|cancelled|timed_out|action_required"
      echo "  Requires: REPO env var, and 'checks: write' on GH_TOKEN"
      exit 0 ;;
  esac
fi
