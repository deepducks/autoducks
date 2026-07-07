#!/usr/bin/env bash
set -euo pipefail

# its::link_sub_issue PARENT_ID CHILD_ID
#
# Links CHILD_ID as a native GitHub sub-issue of PARENT_ID. Emits a single
# token on stdout and returns 0 in every non-catastrophic case (so callers
# using `local r=$(its::link_sub_issue ...)` never abort under `set -e`):
#
#   linked          — POST returned 2xx; relationship established
#   already-linked  — POST returned 422 with an "already exists" body
#   unavailable     — probe reports unavailable; no request was issued
#   forbidden       — probe reports forbidden; no request was issued
#   error           — 5xx or unexpected 4xx after 3 attempts
#
# Retries: transient errors (5xx, network) retry up to 3 times with a
# 1s/2s/4s backoff. 4xx (other than 422 already-exists) do not retry.
its::link_sub_issue() {
  local parent_id="$1"
  local child_id="$2"

  local probe
  probe=$(its::sub_issues_available "$parent_id")

  case "$probe" in
    unavailable) echo "unavailable"; return 0 ;;
    forbidden)   echo "forbidden";   return 0 ;;
  esac

  local attempt=0 max=3 backoff=1
  while (( attempt < max )); do
    local resp_file rc http_code
    resp_file=$(mktemp)
    rc=0
    http_code=$(
      gh api "repos/$REPO/issues/$parent_id/sub_issues" \
        --method POST \
        -F "sub_issue_id=$child_id" \
        --include \
        2>"$resp_file" \
      | awk 'NR==1 { print $2 }'
    ) || rc=$?

    case "${http_code:-}" in
      2*)
        rm -f "$resp_file"
        echo "linked"
        return 0
        ;;
      422)
        if grep -q -i 'already' "$resp_file"; then
          rm -f "$resp_file"
          echo "already-linked"
          return 0
        fi
        rm -f "$resp_file"
        echo "error"
        return 0
        ;;
      401|403)
        rm -f "$resp_file"
        echo "forbidden"
        return 0
        ;;
      404|410)
        rm -f "$resp_file"
        # First call may have missed the probe (e.g. probe returned
        # `error` and we tried anyway). Cache the observation.
        export AUTODUCKS_SUB_ISSUES_STATUS="unavailable"
        echo "unavailable"
        return 0
        ;;
      5*|"")
        rm -f "$resp_file"
        attempt=$((attempt + 1))
        (( attempt < max )) && sleep "$backoff"
        backoff=$((backoff * 2))
        ;;
      *)
        rm -f "$resp_file"
        echo "error"
        return 0
        ;;
    esac
  done

  echo "error"
  return 0
}
