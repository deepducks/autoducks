#!/usr/bin/env bash
set -euo pipefail

git::generate_slug() {
  local id="$1"
  local title="$2"
  local slug
  slug=$(echo "$title" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-' | sed 's/^-//;s/-$//' | head -c 50)
  echo "${id}-${slug}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: git::generate_slug ID TITLE"; echo "  Generate a URL-safe slug from id and title"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
