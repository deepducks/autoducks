#!/usr/bin/env bash
set -euo pipefail

# Stamped so revert can recognise the comment later regardless of which
# credential posted it (#183). Sourced unconditionally rather than guarded on
# `declare -F`: the guarded form silently posted an unstamped comment whenever
# load-config had not run, which is the #183 failure again with no symptom —
# revert strips the labels and deletes nothing.
_CI_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_CI_SH_DIR/../../../core/config/comment-marker.sh"

its::comment_issue() {
  local issue_id="$1"
  local body="$2"
  body="$(comment_marker::stamp "$body")"
  gh issue comment "$issue_id" --repo "$REPO" --body "$body"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: its::comment_issue ISSUE_ID BODY"; echo "  Post a comment on an issue"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
