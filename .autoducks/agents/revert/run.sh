#!/usr/bin/env bash
set -euo pipefail
export AUTODUCKS_AGENT="revert"
source "$(dirname "${BASH_SOURCE[0]}")/../../core/config/load-config.sh"
source "$AUTODUCKS_ROOT/core/feedback/react-to-comment.sh"
source "$AUTODUCKS_ROOT/core/orchestration/parse-waves.sh"

FEATURE="${FEATURE_ISSUE:?FEATURE_ISSUE env var required}"

react_to_comment "${COMMENT_ID:-}" "eyes"

# Get issue body and extract task numbers
ISSUE_BODY=$(its::get_issue "$FEATURE" | jq -r '.body')
YAML_BLOCK=$(echo "$ISSUE_BODY" | awk '/^```yaml[[:space:]]*$/{flag=1;next}/^```[[:space:]]*$/{flag=0}flag')

TASK_NUMBERS=()
if [[ -n "$YAML_BLOCK" ]]; then
  while IFS= read -r num; do
    [[ -n "$num" ]] && TASK_NUMBERS+=("$num")
  done < <(echo "$YAML_BLOCK" | yq '.waves[].tasks[]' 2>/dev/null | grep -E '^[0-9]+$')
fi

# Close task issues
for t in "${TASK_NUMBERS[@]:-}"; do
  its::close_issue "$t" "Reverted by \`${AUTODUCKS_COMMAND} revert\` on #$FEATURE" "not_planned" 2>/dev/null || echo "::warning::Could not close #$t"
done

# Remove labels (current taxonomy + legacy pre-rename labels, so revert
# cleans up issues created by older installs too)
its::remove_label "$FEATURE" "draft" 2>/dev/null || true
for lbl in "Design:draft" "Design:done" "Tactics:crafting" "Tactics:done" \
           "Work:orchestrating" "Work:coding" "Work:done" \
           "Spec:draft" "Spec:plan" "Tactics:ready" "Work:progress" \
           "Ready" "Tactics:single"; do
  its::remove_label "$FEATURE" "$lbl" 2>/dev/null || true
done

# Restore original issue body via edit history
EDIT_HISTORY=$(its::get_issue_edit_history "$FEATURE")
ORIGINAL_BODY=$(echo "$EDIT_HISTORY" | jq -r '
  .data.repository.issue.userContentEdits.nodes
  | map(select(.editor.login != "github-actions" and .editor.login != "github-actions[bot]"))
  | sort_by(.editedAt)
  | last
  | .diff // empty
')

if [[ -n "$ORIGINAL_BODY" ]]; then
  tmpfile=$(mktemp)
  echo "$ORIGINAL_BODY" > "$tmpfile"
  its::update_issue_body "$FEATURE" "$tmpfile"
  rm -f "$tmpfile"
fi

# Delete bot comments
COMMENT_IDS=$(its::list_comments "$FEATURE" | jq -r '.[] | select(.author == "github-actions[bot]" or .author == "github-actions") | .id')
while IFS= read -r cid; do
  [[ -n "$cid" ]] && its::delete_comment "$cid" 2>/dev/null || true
done <<< "$COMMENT_IDS"

react_to_comment "${COMMENT_ID:-}" "+1"
