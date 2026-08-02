#!/usr/bin/env bash
set -euo pipefail

# An edit replaces the body wholesale, so the marker has to be re-applied or the
# status comment stops being recognisable to revert the moment it is edited from
# "running" to "finished" (#183). Sourced unconditionally — see comment-issue.sh
# for why the `declare -F` guard was the wrong shape here.
_UC_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_UC_SH_DIR/../../../core/config/comment-marker.sh"

its::update_comment() {
  local comment_id="$1"
  local body="$2"
  body="$(comment_marker::stamp "$body")"
  gh api "repos/$REPO/issues/comments/$comment_id" --method PATCH -f "body=$body" --silent
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help) echo "Usage: its::update_comment COMMENT_ID BODY"; echo "  Edit an issue comment in place"; echo "  Requires: REPO env var"; exit 0 ;;
  esac
fi
