#!/usr/bin/env bash
set -euo pipefail
export AUTODUCKS_AGENT="revert"
source "$(dirname "${BASH_SOURCE[0]}")/../../core/config/load-config.sh"
source "$AUTODUCKS_ROOT/core/feedback/react-to-comment.sh"
source "$AUTODUCKS_ROOT/core/orchestration/parse-waves.sh"

FEATURE="${FEATURE_ISSUE:?FEATURE_ISSUE env var required}"

react_to_comment "${COMMENT_ID:-}" "eyes"

# Get issue body/labels and extract task numbers
ISSUE_DATA=$(its::get_issue "$FEATURE")
ISSUE_BODY=$(echo "$ISSUE_DATA" | jq -r '.body')
ISSUE_LABELS=$(echo "$ISSUE_DATA" | jq -r '.labels[]')
YAML_BLOCK=$(echo "$ISSUE_BODY" | awk '/^```yaml[[:space:]]*$/{flag=1;next}/^```[[:space:]]*$/{flag=0}flag')

TASK_NUMBERS=()
if [[ -n "$YAML_BLOCK" ]]; then
  while IFS= read -r num; do
    [[ -n "$num" ]] && TASK_NUMBERS+=("$num")
  done < <(echo "$YAML_BLOCK" | yq '.waves[].tasks[]' 2>/dev/null | grep -E '^[0-9]+$')
fi

# Labels applied by the pipeline (current taxonomy + legacy pre-rename names,
# so revert also cleans up issues created by older installs).
PROGRESS_LABELS=(draft "Design:draft" "Design:done" "Tactics:crafting" "Tactics:done" \
                  "Work:orchestrating" "Work:coding" "Work:done" \
                  "Spec:draft" "Spec:plan" "Tactics:ready" "Work:progress" \
                  "Ready" "Tactics:single" "Mode:waves" "Mode:sequential")

HAS_PROGRESS_LABEL=0
for lbl in "${PROGRESS_LABELS[@]}"; do
  if echo "$ISSUE_LABELS" | grep -qxF "$lbl"; then
    HAS_PROGRESS_LABEL=1
    break
  fi
done

BOT_COMMENT_IDS=$(its::list_comments "$FEATURE" | jq -r '.[] | select(.author == "github-actions[bot]" or .author == "github-actions") | .id')

# Already reverted (or never automated): bail here, before the body-restore
# step below picks the *last* non-bot edit as "the original" body. If a
# human edits the issue after a revert already ran, that edit becomes the
# new "last" one, and re-running restore would wrongly treat that
# post-revert edit as the pre-automation body.
if [[ "$HAS_PROGRESS_LABEL" -eq 0 && -z "$BOT_COMMENT_IDS" ]]; then
  its::comment_issue "$FEATURE" "Nothing to revert — no progress labels or bot comments remain." 2>/dev/null || true
  react_to_comment "${COMMENT_ID:-}" "+1"
  exit 0
fi

# Close task issues
for t in "${TASK_NUMBERS[@]:-}"; do
  its::close_issue "$t" "Reverted by \`$(autoducks_command_for revert)\` on #$FEATURE" "not_planned" 2>/dev/null || echo "::debug::Could not close #$t (likely already closed)"
done

# Remove labels
for lbl in "${PROGRESS_LABELS[@]}"; do
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
while IFS= read -r cid; do
  [[ -n "$cid" ]] && its::delete_comment "$cid" 2>/dev/null || true
done <<< "$BOT_COMMENT_IDS"

react_to_comment "${COMMENT_ID:-}" "+1"
