#!/usr/bin/env bash
set -euo pipefail

its::add_label() {
  local issue_id="$1"
  local label="$2"
  gh issue edit "$issue_id" --repo "$REPO" --add-label "$label"
}
