#!/usr/bin/env bash
set -euo pipefail

# git::retrigger_child_check PR_NUMBER SLUG TOKEN — re-fire the child's required
# check for this delivery PR by toggling its draft state (draft → ready fires
# ready_for_review, which the child CI honours as its re-run trigger). This is
# the primary re-trigger mechanism; it must never fall back to a blanket
# `gh workflow run` since that would re-run every check repo-wide instead of
# just the one delivery PR. Only ever called for a metarepo-owned child
# delivery PR (never task iterations), under the child's resolved token.
git::retrigger_child_check() {
  local pr_number="$1" slug="$2" token="$3"
  git::mark_pr_draft "$pr_number" "$slug" "$token" || return 1
  git::mark_pr_ready "$pr_number" "$slug" "$token"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: git::retrigger_child_check PR_NUMBER SLUG TOKEN"; echo "  Re-fire a child's required check for one delivery PR via draft→ready toggle"; echo "  Never triggers a repo-wide workflow run"; exit 0 ;;
  esac
fi
