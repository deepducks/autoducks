#!/usr/bin/env bash
set -euo pipefail

git::list_merged_prs() {
  local base="$1"
  gh pr list --repo "$REPO" --state merged --base "$base" \
    --json number,title,body --limit 100
}
