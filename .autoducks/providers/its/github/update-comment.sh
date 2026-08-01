#!/usr/bin/env bash
set -euo pipefail

its::update_comment() {
  local comment_id="$1"
  local body="$2"
  # An edit replaces the body wholesale, so the marker has to be re-applied or
  # the status comment stops being recognisable to revert the moment it is
  # edited from "running" to "finished" (#183).
  if declare -F comment_marker::stamp >/dev/null 2>&1; then
    body="$(comment_marker::stamp "$body")"
  fi
  gh api "repos/$REPO/issues/comments/$comment_id" --method PATCH -f "body=$body" --silent
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: its::update_comment COMMENT_ID BODY"; echo "  Edit an issue comment in place"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
