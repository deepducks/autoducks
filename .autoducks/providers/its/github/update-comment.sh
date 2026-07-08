#!/usr/bin/env bash
set -euo pipefail

its::update_comment() {
  local comment_id="$1"
  local body="$2"
  gh api "repos/$REPO/issues/comments/$comment_id" --method PATCH -f "body=$body" --silent
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: its::update_comment COMMENT_ID BODY"; echo "  Edit an issue comment in place"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
