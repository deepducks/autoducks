#!/usr/bin/env bash
set -euo pipefail

its::remove_label() {
  local issue_id="$1"
  local label="$2"
  gh issue edit "$issue_id" --repo "$REPO" --remove-label "$label" || return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: its::remove_label ISSUE_ID LABEL"; echo "  Remove a label from an issue"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
