#!/usr/bin/env bash
set -euo pipefail

# Resolve the merge method to use for this repo.
# Honors AUTODUCKS_MERGE_METHOD (merge|squash|rebase|auto). When "auto" (or
# unset), detects an allowed method from the repo settings, preferring
# merge → squash → rebase.
git::_resolve_merge_method() {
  local configured="${AUTODUCKS_MERGE_METHOD:-auto}"
  if [[ -n "$configured" && "$configured" != "auto" ]]; then
    echo "$configured"
    return 0
  fi

  local allowed
  allowed="$(gh api "repos/$REPO" 2>/dev/null || echo '{}')"
  if [[ "$(echo "$allowed" | jq -r '.allow_merge_commit // false')" == "true" ]]; then
    echo "merge"
  elif [[ "$(echo "$allowed" | jq -r '.allow_squash_merge // false')" == "true" ]]; then
    echo "squash"
  elif [[ "$(echo "$allowed" | jq -r '.allow_rebase_merge // false')" == "true" ]]; then
    echo "rebase"
  else
    # Nothing detected (e.g. API unavailable) — fall back to merge and let the
    # API surface the real error.
    echo "merge"
  fi
}

# Merge a pull request using the resolved merge method.
# Exit codes:
#   0 — merged
#   2 — the resolved method is not allowed on the repo (configuration error;
#       do NOT rebase-retry, it won't help)
#   1 — any other failure (e.g. branch behind / conflict; rebase-retry may help)
# An optional second argument "auto" arms GitHub's auto-merge instead of merging
# now, so the repo's own required checks gate the merge. Callers that merge
# machinery into a consumer repo want this: without it the merge lands before
# any CI the repo configured has a chance to run.
git::merge_pr() {
  local pr_number="$1"
  local when="${2:-now}"
  local method
  method="$(git::_resolve_merge_method)"

  local -a _auto=()
  [[ "$when" == "auto" ]] && _auto=(--auto)

  if gh pr merge "$pr_number" --repo "$REPO" --"$method" "${_auto[@]}" >/dev/null 2>&1; then
    return 0
  fi
  # No immediate-merge fallback here. `auto` exists so the consumer's required
  # checks gate the merge; merging anyway when GitHub rejects --auto — the
  # default for a repo that never enabled auto-merge — would land the PR before
  # any CI started, which is the precise outcome the caller asked to prevent.
  # Report and leave the PR open for a human instead.
  if [[ "$when" == "auto" ]]; then
    echo "::warning::merge_pr: auto-merge is not enabled on $REPO — leaving #$pr_number open rather than merging ahead of its checks. Enable auto-merge in the repository settings, or merge it manually." >&2
    return 1
  fi

  # Fallback to the REST API, capturing stderr for classification.
  local err
  err="$(gh api "repos/$REPO/pulls/$pr_number/merge" \
    -X PUT -f merge_method="$method" 2>&1 >/dev/null)" && return 0

  if echo "$err" | grep -qiE 'not allowed on this repository|merge method .* not allowed'; then
    echo "git::merge_pr: '$method' merges are not allowed on $REPO. Set defaults.merge_method to an allowed method (merge|squash|rebase) or enable it in the repo settings." >&2
    return 2
  fi

  echo "git::merge_pr: failed to merge PR #$pr_number using '$method': $err" >&2
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: git::merge_pr PR_NUMBER [now|auto]"; echo "  Merge a pull request using the resolved merge method"; echo "  auto: arm host auto-merge so required checks gate it; returns 1 (PR left open) if unavailable"; echo "  Method: AUTODUCKS_MERGE_METHOD (merge|squash|rebase|auto; default auto-detects)"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
