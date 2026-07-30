#!/usr/bin/env bash
set -euo pipefail

# its::get_parent ISSUE_ID → parent issue number on stdout, empty when the issue
# genuinely has no parent.
#
# Exit code carries the distinction the caller needs:
#   0 — the query ran; stdout is the parent number, or empty for "no parent"
#   1 — the query itself failed (network, auth, API shape); stdout is empty
#
# `GET /repos/{owner}/{repo}/issues/{n}` has no `parent` field: reading
# `.parent.number` off it always yields empty, which is indistinguishable from a
# genuine orphan. The sub-issue relationship is only exposed through GraphQL, so
# that is what this asks. `parent { number }` is null for a top-level issue,
# which is the empty-stdout-exit-0 case.
its::get_parent() {
  local issue_id="$1"
  local owner="${REPO%%/*}" name="${REPO##*/}"
  local out

  out="$(gh api graphql \
    -f query='query($owner:String!,$name:String!,$number:Int!){
      repository(owner:$owner,name:$name){ issue(number:$number){ parent { number } } }
    }' \
    -F owner="$owner" -F name="$name" -F number="$issue_id" \
    --jq '.data.repository.issue.parent.number // empty' 2>/dev/null)" || return 1

  printf '%s' "$out"
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help)
      echo "Usage: its::get_parent ISSUE_ID"
      echo "  Print the parent issue number, or nothing when the issue has no parent"
      echo "  Exit 0 = query ran (empty stdout means no parent); exit 1 = query failed"
      echo "  Requires: REPO env var"
      exit 0
      ;;
  esac
fi
