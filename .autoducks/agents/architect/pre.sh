#!/usr/bin/env bash
set -euo pipefail
export AUTODUCKS_AGENT="architect"
source "$(dirname "${BASH_SOURCE[0]}")/../../core/config/load-config.sh"
source "$AUTODUCKS_ROOT/core/feedback/react-to-comment.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-failure.sh"
source "$AUTODUCKS_ROOT/core/feedback/progress-labels.sh"
source "$AUTODUCKS_ROOT/core/feedback/status-comment.sh"
source "$AUTODUCKS_ROOT/core/orchestration/tactical-zone.sh"

rm -f /tmp/autoducks-pre-failed

trap '_rc=$?; notify_failure "$ISSUE_NUM" "$RUN_ID" "" 2>/dev/null || true; \
      status_comment::fail "$ISSUE_NUM" 2>/dev/null || true; \
      react_to_comment "${COMMENT_ID:-}" "confused" 2>/dev/null || true; \
      progress_labels::abort "$ISSUE_NUM" "Design:draft" 2>/dev/null || true; \
      touch /tmp/autoducks-pre-failed; \
      exit $_rc' ERR

react_to_comment "${COMMENT_ID:-}" "eyes"
status_comment::start "$ISSUE_NUM"

progress_labels::ensure
progress_labels::start "$ISSUE_NUM" "Design:draft" "Design:done"

# Fetch issue content for the LLM
its::get_issue "$ISSUE_NUM" | jq -r '"# " + .title + "\n\n" + .body' > /tmp/issue-request.md

# Fetch raw body (no title prefix) for zone splitting
its::get_issue "$ISSUE_NUM" | jq -r '.body' > /tmp/issue-body-raw.md

# If the current body already has a tactical zone, stash it so post.sh can
# re-emit it verbatim; the LLM re-authors the design zone from scratch.
rm -f /tmp/tactical-zone-preserved.flag /tmp/tactical-zone-preserved.md
if body_has_markers /tmp/issue-body-raw.md; then
  SPLIT_RC=0
  split_body /tmp/issue-body-raw.md /tmp/design-zone-discard.md /tmp/tactical-zone-preserved.md || SPLIT_RC=$?
  if [[ "$SPLIT_RC" -eq 2 ]]; then
    its::comment_issue "$ISSUE_NUM" "❌ Tactical zone markers are malformed (mismatched or out of order). Please restore the \`<!-- autoducks:tactical:begin -->\` and \`<!-- autoducks:tactical:end -->\` markers in the issue body and re-run \`${AUTODUCKS_COMMAND} architect\`."
    _AUTODUCKS_NOTIFIED=1
    status_comment::fail "$ISSUE_NUM" 2>/dev/null || true
    react_to_comment "$COMMENT_ID" "confused"
    touch /tmp/autoducks-pre-failed
    exit 1
  fi
  # Explicit signal — do NOT use `[[ -s ]]`, an empty-but-present tactical zone
  # is legitimate and its markers must still be re-emitted.
  touch /tmp/tactical-zone-preserved.flag
fi
