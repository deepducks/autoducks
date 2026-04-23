#!/usr/bin/env bash
set -euo pipefail

git::generate_slug() {
  local id="$1"
  local title="$2"
  local slug
  slug=$(echo "$title" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-' | sed 's/^-//;s/-$//' | head -c 50)
  echo "${id}-${slug}"
}
