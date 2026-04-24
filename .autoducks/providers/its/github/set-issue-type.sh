#!/usr/bin/env bash
set -euo pipefail

its::set_issue_type() {
  local issue_id="$1"
  local type="$2"
  gh api "repos/$REPO/issues/$issue_id" --method PATCH -f "type=$type" --silent
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: its::set_issue_type ISSUE_ID TYPE"; echo "  Set the issue type (e.g. Feature, Task)"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
