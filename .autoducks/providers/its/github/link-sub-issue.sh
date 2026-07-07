#!/usr/bin/env bash
set -euo pipefail

# its::link_sub_issue PARENT_ID CHILD_ID
#
# PARENT_ID and CHILD_ID are asymmetric:
#   PARENT_ID — the parent issue's number (URL path; probe and POST both
#               address the parent by number).
#   CHILD_ID  — the child issue's REST database id (the sub_issue_id POST
#               body).
#
# Links CHILD_ID as a native GitHub sub-issue of PARENT_ID. Emits a single
# token on stdout and returns 0 in every non-catastrophic case (so callers
# using `local r=$(its::link_sub_issue ...)` never abort under `set -e`):
#
#   linked          — POST returned 2xx; relationship established
#   already-linked  — POST returned 422 with an "already exists" body
#   unavailable     — probe reports unavailable; no request was issued
#   forbidden       — probe reports forbidden; no request was issued
#   error           — 5xx after 3 attempts, unexpected 4xx, or a POST
#                     404/410 (bad argument, e.g. wrong sub_issue_id; the
#                     probe already established availability)
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
        # The probe already established endpoint availability for this repo.
        # A 404/410 on write with a valid parent is a bad-argument error
        # (e.g. wrong sub_issue_id), NOT a disabled feature. Classify as a
        # retry-able error and do NOT poison the shared availability cache.
        echo "error"
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
