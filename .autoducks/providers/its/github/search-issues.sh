#!/usr/bin/env bash
set -euo pipefail

# its::search_issues QUERY
#
# Cheap dedup pre-filter: searches issues (PRs excluded by default) by
# title/body keywords via `gh search issues` so callers can check for an
# existing issue before creating a new one, without paging the whole
# backlog through its::list_issues.
#
# Emits a JSON array of {number, title, body, labels, updatedAt}.
its::search_issues() {
  local query="$1"

  gh search issues "$query" --repo "$REPO" --json number,title,body,labels,updatedAt \
    --jq '[.[] | {number, title, body, labels: [.labels[].name], updatedAt}]'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: its::search_issues QUERY"; echo "  Search issues by keyword (JSON array), used as a dedup pre-filter"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
