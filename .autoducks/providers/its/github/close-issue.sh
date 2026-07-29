#!/usr/bin/env bash
set -euo pipefail

# its::close_issue ISSUE_ID [COMMENT] [REASON]
#
# Closes ISSUE_ID, optionally posting COMMENT first and passing REASON
# through to `gh issue close`. REASON is validated and mapped before any
# `gh` call is made:
#
#   (empty/omitted)   → --reason omitted entirely (gh default)
#   completed         → --reason completed
#   not_planned       → --reason "not planned"
#   not planned       → --reason "not planned"  (already-CLI spelling)
#   duplicate         → --reason duplicate
#   anything else     → rejected; no gh call is made
#
# Returns:
#   0 — the issue is closed. Either this call closed it, or it was already
#       closed (logged ::debug::).
#   1 — the close failed and the issue is still open. A single-line
#       ::warning:: with the gh stderr has been emitted.
#   2 — invalid REASON. No gh call was made; an ::error:: has been emitted.
its::close_issue() {
  local issue_id="$1"
  local comment="${2:-}"
  local reason="${3:-}"

  local mapped_reason=""
  case "$reason" in
    "") : ;;
    completed) mapped_reason="completed" ;;
    not_planned|"not planned") mapped_reason="not planned" ;;
    duplicate) mapped_reason="duplicate" ;;
    *)
      echo "::error::its::close_issue: invalid reason '${reason}' (expected: completed|not_planned|duplicate)" >&2
      return 2
      ;;
  esac

  local args=(--repo "$REPO")
  if [[ -n "$comment" ]]; then
    args+=(--comment "$comment")
  fi
  if [[ -n "$mapped_reason" ]]; then
    args+=(--reason "$mapped_reason")
  fi

  local err_file
  err_file="$(mktemp)"
  local rc=0
  gh issue close "$issue_id" "${args[@]}" 2>"$err_file" || rc=$?

  if [[ "$rc" -eq 0 ]]; then
    rm -f "$err_file"
    return 0
  fi

  local err_msg
  err_msg="$(tr '\n' ' ' < "$err_file" | sed 's/[[:space:]]\+/ /g; s/^[[:space:]]*//; s/[[:space:]]*$//')"
  rm -f "$err_file"

  local state
  state="$(gh issue view "$issue_id" --repo "$REPO" --json state --jq '.state' 2>/dev/null || true)"

  if [[ "$state" == "CLOSED" ]]; then
    echo "::debug::its::close_issue: #${issue_id} already closed; no-op" >&2
    return 0
  fi

  echo "::warning::its::close_issue: could not close #${issue_id} — ${err_msg}" >&2
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: its::close_issue ISSUE_ID [COMMENT] [REASON]"; echo "  Close an issue, optionally with a comment and a reason (completed|not_planned|duplicate)"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
