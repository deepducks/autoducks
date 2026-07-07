#!/usr/bin/env bash
set -euo pipefail

git::create_pr() {
  local head="$1" base="$2" title="$3" body="${4:-}" draft="${5:-false}"
  local args=(--repo "$REPO" --base "$base" --head "$head" --title "$title" --body "$body")
  [[ "$draft" == "true" ]] && args+=(--draft)
  local url
  url=$(gh pr create "${args[@]}")
  echo "$url" | grep -oE '[0-9]+$'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: git::create_pr HEAD BASE TITLE [BODY] [DRAFT]"; echo "  Create a pull request, returns PR number"; echo "  DRAFT: \"true\" to create as draft (default false)"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
