#!/usr/bin/env bash
set -euo pipefail
export AUTODUCKS_AGENT="tactical"
source "$(dirname "${BASH_SOURCE[0]}")/../../core/config/load-config.sh"
source "$AUTODUCKS_ROOT/core/feedback/react-to-comment.sh"
source "$AUTODUCKS_ROOT/core/orchestration/build-revision-context.sh"

react_to_comment "$COMMENT_ID" "eyes"

# Fetch issue content
its::get_issue "$ISSUE_NUM" | jq -r '"# " + .title + "\n\n" + .body' > /tmp/issue-request.md

# Determine if this is a revision
ISSUE_DATA=$(its::get_issue "$ISSUE_NUM")
ISSUE_LABELS=$(echo "$ISSUE_DATA" | jq -r '.labels[]')
IS_REVISION="false"

if echo "$ISSUE_LABELS" | grep -q "Ready"; then
  IS_REVISION="true"
fi

if [[ "$IS_REVISION" == "true" ]]; then
  # Get existing task numbers from YAML block in issue body
  ISSUE_BODY=$(echo "$ISSUE_DATA" | jq -r '.body')
  YAML_BLOCK=$(echo "$ISSUE_BODY" | awk '/^```yaml[[:space:]]*$/{flag=1;next}/^```[[:space:]]*$/{flag=0}flag')
  OLD_NUMBERS=""
  if [[ -n "$YAML_BLOCK" ]]; then
    OLD_NUMBERS=$(echo "$YAML_BLOCK" | yq '.waves[].tasks[]' 2>/dev/null | grep -E '^[0-9]+$' | tr '\n' ' ')
  fi

  build_revision_context "$ISSUE_NUM" "$OLD_NUMBERS" /tmp/conversation.md
  export OLD_NUMBERS
fi

export IS_REVISION

# Persist across GHA steps
if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "IS_REVISION=$IS_REVISION" >> "$GITHUB_ENV"
  echo "OLD_NUMBERS=${OLD_NUMBERS:-}" >> "$GITHUB_ENV"
fi
