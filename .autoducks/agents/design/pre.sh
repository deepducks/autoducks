#!/usr/bin/env bash
set -euo pipefail
export AUTODUCKS_AGENT="design"
source "$(dirname "${BASH_SOURCE[0]}")/../../core/config/load-config.sh"
source "$AUTODUCKS_ROOT/core/feedback/react-to-comment.sh"

react_to_comment "$COMMENT_ID" "eyes"

# Fetch issue content for the LLM
its::get_issue "$ISSUE_NUM" | jq -r '"# " + .title + "\n\n" + .body' > /tmp/issue-request.md
