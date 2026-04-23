#!/usr/bin/env bash
set -euo pipefail

# React to a comment with an emoji
# Usage: source this file, then call react_to_comment <comment_id> <reaction>
# Reactions: eyes (started), +1 (success), confused (failure)
react_to_comment() {
  local comment_id="${1:-}"
  local reaction="${2:-eyes}"

  [[ -z "$comment_id" || "$comment_id" == "0" ]] && return 0

  its::react_to_comment "$comment_id" "$reaction" || true
}
