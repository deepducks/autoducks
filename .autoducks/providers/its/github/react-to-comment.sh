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
