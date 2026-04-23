#!/usr/bin/env bash
set -euo pipefail

its::delete_comment() {
  local comment_id="$1"
  gh api "repos/$REPO/issues/comments/$comment_id" --method DELETE --silent || return 0
}
