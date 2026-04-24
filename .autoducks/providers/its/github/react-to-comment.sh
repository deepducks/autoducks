#!/usr/bin/env bash
set -euo pipefail

its::react_to_comment() {
  local comment_id="$1"
  local reaction="$2"

  if [[ -z "$comment_id" || "$comment_id" == "0" ]]; then
    return 0
  fi

  gh api --method POST "repos/$REPO/issues/comments/$comment_id/reactions" \
    -f "content=$reaction" --silent || return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: its::react_to_comment COMMENT_ID REACTION"; echo "  Add an emoji reaction to a comment"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
