#!/usr/bin/env bash
set -euo pipefail

its::remove_label() {
  local issue_id="$1"
  local label="$2"
  gh issue edit "$issue_id" --repo "$REPO" --remove-label "$label" || return 0
}
