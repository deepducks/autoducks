#!/usr/bin/env bash
set -euo pipefail

# Retry an agent invocation when plan parsing fails
# Usage: retry_on_parse_failure <issue_id> <parse_error_file> <max_retries>
# Returns 0 if retry succeeded, 1 if all retries exhausted
retry_on_parse_failure() {
  local issue_id="$1"
  local parse_error_file="$2"
  local max_retries="${3:-1}"

  [[ ! -f "$parse_error_file" ]] && return 1

  local error_context
  error_context=$(cat "$parse_error_file")

  echo "$error_context"
  return 1
}
