#!/usr/bin/env bash
set -euo pipefail
export AUTODUCKS_AGENT="tactical"
source "$(dirname "${BASH_SOURCE[0]}")/../../core/config/load-config.sh"
source "$AUTODUCKS_ROOT/core/feedback/react-to-comment.sh"
source "$AUTODUCKS_ROOT/core/orchestration/build-revision-context.sh"
source "$AUTODUCKS_ROOT/core/orchestration/tactical-zone.sh"

react_to_comment "$COMMENT_ID" "eyes"

source "$AUTODUCKS_ROOT/core/feedback/progress-labels.sh"
progress_labels::ensure
progress_labels::start "$ISSUE_NUM" "Tactics:crafting" "Tactics:ready"

# Fetch issue content — full body with title prefix for the LLM's main input
its::get_issue "$ISSUE_NUM" | jq -r '"# " + .title + "\n\n" + .body' > /tmp/issue-request.md

# Fetch raw body (no title prefix) for zone splitting
ISSUE_DATA=$(its::get_issue "$ISSUE_NUM")
ISSUE_LABELS=$(echo "$ISSUE_DATA" | jq -r '.labels[]')
echo "$ISSUE_DATA" | jq -r '.body' > /tmp/issue-body-raw.md

# Determine if this is a revision
IS_REVISION="false"
if echo "$ISSUE_LABELS" | grep -q "Ready"; then
  IS_REVISION="true"
fi

# Split body into design and tactical zones. The tactical-zone markers are the
# single source of truth for the zone boundary — a label never overrides them.
# Case A: markers present — normal split.
# Case B: no markers — the whole body is the author-owned design zone,
#         preserved verbatim regardless of any label; tactical zone starts empty.
if body_has_markers /tmp/issue-body-raw.md; then
  SPLIT_RC=0
  split_body /tmp/issue-body-raw.md /tmp/design-zone.md /tmp/tactical-zone-current.md || SPLIT_RC=$?
  if [[ "$SPLIT_RC" -eq 2 ]]; then
    its::comment_issue "$ISSUE_NUM" "❌ Tactical zone markers are malformed (mismatched or out of order). Please restore the \`<!-- autoducks:tactical:begin -->\` and \`<!-- autoducks:tactical:end -->\` markers in the issue body and re-run \`/agents devise\`."
    react_to_comment "$COMMENT_ID" "confused"
    exit 1
  fi
else
  cp /tmp/issue-body-raw.md /tmp/design-zone.md
  : > /tmp/tactical-zone-current.md
fi

if [[ "$IS_REVISION" == "true" ]]; then
  # Get existing task numbers from YAML block in the tactical zone
  YAML_BLOCK=$(awk '/^```yaml[[:space:]]*$/{flag=1;next}/^```[[:space:]]*$/{flag=0}flag' /tmp/tactical-zone-current.md)
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
