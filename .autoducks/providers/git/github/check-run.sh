#!/usr/bin/env bash
set -euo pipefail

# GitHub Checks API primitives. Used by the reviewer agent to expose its
# verdict as a first-class Check-run so it can gate merges via branch
# protection / rulesets. Requires `checks: write`.
#
# IMPORTANT — token identity: the Checks API is GitHub-App-only. A Personal
# Access Token (classic or fine-grained) is rejected with
# `403 "You must authenticate via a GitHub App."`, so when the agent step is
# authenticated with AUTODUCKS_PAT (as the reviewer's pre/post steps are, to
# author reviews/comments under the fork identity and re-trigger workflows),
# the bare GH_TOKEN cannot create or conclude a check-run. We therefore route
# just these two calls through the Actions GITHUB_TOKEN — itself a GitHub App
# installation token, which the Checks API accepts — falling back to GH_TOKEN
# for non-PAT setups / local runs where GITHUB_TOKEN is unset.
_git::checks_token() { printf '%s' "${GITHUB_TOKEN:-${GH_TOKEN:-}}"; }

# git::start_check_run NAME HEAD_SHA → echoes the new check-run id (numeric).
# Creates an in-progress check attached to the given commit. On any API error
# it returns non-zero and echoes nothing, so callers never capture an error
# body (e.g. the 403 JSON) as if it were an id.
git::start_check_run() {
  local name="$1"
  local head_sha="$2"
  local resp id
  resp=$(jq -n --arg name "$name" --arg sha "$head_sha" \
      '{name: $name, head_sha: $sha, status: "in_progress"}' \
    | GH_TOKEN="$(_git::checks_token)" gh api "repos/$REPO/check-runs" \
        --method POST \
        -H "Accept: application/vnd.github+json" \
        --input - 2>/dev/null) || return 1
  id=$(jq -r '.id // empty' <<<"$resp" 2>/dev/null || true)
  [[ "$id" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$id"
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
  | GH_TOKEN="$(_git::checks_token)" gh api "repos/$REPO/check-runs/$check_run_id" \
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
