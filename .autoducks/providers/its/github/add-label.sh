#!/usr/bin/env bash
set -euo pipefail

its::add_label() {
  local issue_id="$1"
  local label="$2"
  gh issue edit "$issue_id" --repo "$REPO" --add-label "$label"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: its::add_label ISSUE_ID LABEL"; echo "  Add a label to an issue"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
