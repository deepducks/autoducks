#!/usr/bin/env bash
set -euo pipefail

git::create_pr() {
  local head="$1" base="$2" title="$3" body="${4:-}"
  local url
  url=$(gh pr create --repo "$REPO" --base "$base" --head "$head" \
    --title "$title" --body "$body")
  echo "$url" | grep -oE '[0-9]+$'
}
