#!/usr/bin/env bash
set -euo pipefail

# its::list_issues STATE [LIMIT] [EXTRA_FILTER]
#
# Enumerates the backlog. STATE is one of open|closed|all. LIMIT, when
# given, is bounded above by the `product.max_issues_per_run` config value
# (defaults to 100 when unset — matches pre.sh's and the `product` config
# block's default) so a single call can never pull more than the run is
# budgeted for; when omitted, the configured max is used outright.
# EXTRA_FILTER, when given, is passed through as a `gh issue list --search`
# qualifier string (e.g. "label:bug -label:triaged").
#
# Emits a JSON array of {number, title, body, labels, type, updatedAt}.
its::list_issues() {
  local state="${1:-open}"
  local limit="${2:-}"
  local extra_filter="${3:-}"

  local max_issues
  max_issues="$(jq -r '.product.max_issues_per_run // 100' "$AUTODUCKS_ROOT/autoducks.json" 2>/dev/null)"
  [[ -z "$max_issues" || "$max_issues" == "null" ]] && max_issues=100

  local effective_limit="$max_issues"
  if [[ "$limit" =~ ^[0-9]+$ ]] && (( limit < max_issues )); then
    effective_limit="$limit"
  fi

  local gh_args=(--repo "$REPO" --state "$state" --limit "$effective_limit" \
    --json number,title,body,labels,issueType,updatedAt)
  [[ -n "$extra_filter" ]] && gh_args+=(--search "$extra_filter")

  gh issue list "${gh_args[@]}" \
    --jq '[.[] | {number, title, body, labels: [.labels[].name], type: (.issueType.name // null), updatedAt}]'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: its::list_issues STATE [LIMIT] [EXTRA_FILTER]"; echo "  List backlog issues (JSON array), bounded to product.max_issues_per_run"; echo "  Requires: REPO, AUTODUCKS_ROOT env vars"; exit 0 ;;
  esac
fi
