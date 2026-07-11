#!/usr/bin/env bash
# Commit-message lint (warn-only).
#
# Flags a closing keyword (Close(s|d)/Fix(es|ed)/Resolve(s|d) #N) against an
# issue that already has an OPEN delivery PR — a signal that a direct commit
# duplicates work the pipeline is already landing. It never fails the build:
# a direct push to main has already landed by the time this runs, so the
# only useful outcome here is a heads-up.
#
# Sourced (not executed) so both the caller (workflow step) and
# test/unit-commit-lint.sh can call its functions directly; the latter stubs
# git::list_open_prs instead of hitting the real git provider.
set -euo pipefail

COMMIT_LINT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../orchestration/branch-prefix.sh
source "$COMMIT_LINT_DIR/../orchestration/branch-prefix.sh"

# commit_lint::collect_commits → in-scope commit messages for this trigger:
# the PR's commits on `pull_request`, or the pushed range on `push`.
commit_lint::collect_commits() {
  if [[ "${GITHUB_EVENT_NAME:-}" == "pull_request" && -n "${GITHUB_BASE_REF:-}" ]]; then
    git log --format=%B "origin/${GITHUB_BASE_REF}..HEAD" 2>/dev/null || git log -1 --format=%B HEAD
  elif [[ -n "${BEFORE_SHA:-}" && "$BEFORE_SHA" != "0000000000000000000000000000000000000000" ]]; then
    git log --format=%B "${BEFORE_SHA}..${GITHUB_SHA:-HEAD}" 2>/dev/null || git log -1 --format=%B HEAD
  else
    git log -1 --format=%B HEAD
  fi
}

# commit_lint::extract_refs COMMIT_MESSAGES → deduped "#N" refs that use a
# closing keyword. A non-closing reference (`refs #N`, `re #N`) never matches.
commit_lint::extract_refs() {
  local messages="$1"
  { grep -oiE '(^|[^[:alnum:]])(clos(e|es|ed)|fix(es|ed)?|resolv(e|es|ed)) +#[0-9]+' <<<"$messages" \
      | grep -oE '#[0-9]+' \
      | sort -u; } || true
}

# commit_lint::has_open_delivery_pr REF ("#N") → 0 if some open PR against
# AUTODUCKS_INTEGRATION_BRANCH resolves (via resolve_feature_num_from_pr) to
# the same feature/bug number as REF.
commit_lint::has_open_delivery_pr() {
  local ref="$1"
  local num="${ref#\#}"
  local prs count i head_ref body resolved
  prs="$(git::list_open_prs "${AUTODUCKS_INTEGRATION_BRANCH:-}")" || return 1
  count="$(jq 'length' <<<"$prs")"
  for ((i = 0; i < count; i++)); do
    head_ref="$(jq -r ".[$i].headRefName" <<<"$prs")"
    body="$(jq -r ".[$i].body // \"\"" <<<"$prs")"
    resolved="$(resolve_feature_num_from_pr "$head_ref" "$body")"
    if [[ -n "$resolved" && "$resolved" == "$num" ]]; then
      return 0
    fi
  done
  return 1
}

# commit_lint::scan COMMIT_MESSAGES → emits `::warning::` (plus a
# step-summary line) for each closing-keyword ref that already has an open
# delivery PR. Warn-only: always returns 0.
commit_lint::scan() {
  local messages="$1" refs ref
  refs="$(commit_lint::extract_refs "$messages")"
  while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    if commit_lint::has_open_delivery_pr "$ref"; then
      local msg="Commit message closes ${ref}, which already has an open delivery PR — this push may duplicate work the pipeline is already landing."
      echo "::warning::${msg}"
      [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && echo "- ${msg}" >> "$GITHUB_STEP_SUMMARY"
    fi
  done <<< "$refs"
  return 0
}
