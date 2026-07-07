#!/usr/bin/env bash
set -euo pipefail

# its::sub_issues_available ISSUE_ID
#
# Probes whether the sub-issues REST API is functional for the current
# repository. The probe issues a read-only GET request against the
# sub-issues endpoint of ISSUE_ID (any issue in the repo works — the
# feature is per-repo, not per-issue).
#
# Emits one of the following tokens to stdout and returns 0 always
# (never exits non-zero — probing is best-effort):
#
#   available    — endpoint returned 2xx with a JSON array body
#   unavailable  — endpoint returned 404 or 410 (feature disabled or
#                   the "sub_issues" API is not exposed on this repo)
#   forbidden    — endpoint returned 401 or 403 (token lacks scope)
#   error        — network error, 5xx, or any other non-2xx response
#
# The result is cached in the process environment via
# AUTODUCKS_SUB_ISSUES_STATUS after the first call; subsequent calls
# short-circuit.
its::sub_issues_available() {
  local issue_id="$1"

  if [[ -n "${AUTODUCKS_SUB_ISSUES_STATUS:-}" ]]; then
    echo "$AUTODUCKS_SUB_ISSUES_STATUS"
    return 0
  fi

  local http_code
  http_code=$(
    gh api "repos/$REPO/issues/$issue_id/sub_issues" \
      --include \
      -H "Accept: application/vnd.github+json" \
      2>/dev/null \
    | awk 'NR==1 { print $2 }'
  ) || true

  local status
  case "${http_code:-}" in
    2*) status="available" ;;
    401|403) status="forbidden" ;;
    404|410) status="unavailable" ;;
    *)  status="error" ;;
  esac

  export AUTODUCKS_SUB_ISSUES_STATUS="$status"
  echo "$status"
}
