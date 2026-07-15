#!/usr/bin/env bash
set -euo pipefail
export AUTODUCKS_AGENT="architect"
source "$(dirname "${BASH_SOURCE[0]}")/../../core/config/load-config.sh"
source "$AUTODUCKS_ROOT/core/feedback/react-to-comment.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-failure.sh"
source "$AUTODUCKS_ROOT/core/feedback/progress-labels.sh"
source "$AUTODUCKS_ROOT/core/feedback/status-comment.sh"
source "$AUTODUCKS_ROOT/core/orchestration/tactical-zone.sh"
source "$AUTODUCKS_ROOT/core/context/resolve-context.sh"

rm -f "$AUTODUCKS_PRE_FAILED_MARKER"
mkdir -p "$AUTODUCKS_MARKER_DIR"

trap '_rc=$?; notify_failure "$ISSUE_NUM" "$RUN_ID" "" 2>/dev/null || true; \
      status_comment::fail "$ISSUE_NUM" 2>/dev/null || true; \
      react_to_comment "${COMMENT_ID:-}" "confused" 2>/dev/null || true; \
      progress_labels::abort "$ISSUE_NUM" "Design:draft" 2>/dev/null || true; \
      touch "$AUTODUCKS_PRE_FAILED_MARKER"; \
      exit $_rc' ERR

source "$AUTODUCKS_ROOT/core/orchestration/delivery-phase.sh"

ISSUE_LABELS=$(its::get_issue "$ISSUE_NUM" | jq -r '.labels[]?')
if delivery_phase::started "$ISSUE_NUM" "$ISSUE_LABELS"; then
  its::comment_issue "$ISSUE_NUM" "🔒 **Design is locked — execution has already started.**

Re-running the Architect now could invalidate work that is already in flight
(open task branches/PRs, the pipeline branch, and the Maestro's wave state).

To change the design, first unwind the delivery with \`${AUTODUCKS_COMMAND} revert\`
(undo the plan, keep the issue) or \`${AUTODUCKS_COMMAND} close\` (full teardown),
then re-run \`${AUTODUCKS_COMMAND} architect\`."
  react_to_comment "${COMMENT_ID:-}" "confused"
  touch "$AUTODUCKS_PRE_FAILED_MARKER"   # tells post.sh to no-op
  exit 0
fi

react_to_comment "${COMMENT_ID:-}" "eyes"
status_comment::start "$ISSUE_NUM"

progress_labels::ensure
progress_labels::start "$ISSUE_NUM" "Design:draft" "Design:done"

# Fetch issue content for the LLM (title+body → /tmp/issue-request.md, raw
# body → /tmp/issue-body-raw.md, last-20 comments appended under the
# "Reviewer feedback / adjustments" heading) via the shared context resolver.
resolve_context "architect" "$ISSUE_NUM"

# Decode the steering prompt (free-text prose from the triggering comment,
# base64-encoded by parse-directive.sh) to a stable file. Advisory only — it
# is never written into the design body or interpolated into a shell command.
# Always-on override, not a manifest part — appended after the comment
# window resolve_context already wrote above.
rm -f /tmp/steering-prompt.md
if [[ -n "${STEERING_PROMPT:-}" ]]; then
  printf '%s' "$STEERING_PROMPT" | base64 -d > /tmp/steering-prompt.md
fi
if [[ -s /tmp/steering-prompt.md ]]; then
  {
    cat /tmp/steering-prompt.md
    echo ""
  } >> /tmp/issue-request.md
fi

# If the current body already has a tactical zone, strip it: the design is
# changing, so the old plan (and its task issues) would go stale. post.sh
# publishes a design-only body and tears the old plan down.
rm -f /tmp/architect-strip-tactical.flag /tmp/architect-dropped-tasks.txt /tmp/architect-clear-tactics.flag

# Record any completed/in-progress tactics labels so post.sh can drop them once
# a design-only body is republished — independent of whether the old body still
# carries parseable tactical markers (a manual edit can desync the two).
while IFS= read -r _lbl; do
  case "$_lbl" in
    "Tactics:done"|"Tactics:crafting") echo "$_lbl" >> /tmp/architect-clear-tactics.flag ;;
  esac
done <<< "$ISSUE_LABELS"

if body_has_markers /tmp/issue-body-raw.md; then
  SPLIT_RC=0
  split_body /tmp/issue-body-raw.md /tmp/design-zone-discard.md /tmp/tactical-zone-discard.md || SPLIT_RC=$?
  if [[ "$SPLIT_RC" -eq 2 ]]; then
    its::comment_issue "$ISSUE_NUM" "❌ Tactical zone markers are malformed (mismatched or out of order). Please restore the \`<!-- autoducks:tactical:begin -->\` and \`<!-- autoducks:tactical:end -->\` markers in the issue body and re-run \`$(autoducks_command_for architect)\`."
    _AUTODUCKS_NOTIFIED=1
    status_comment::fail "$ISSUE_NUM" 2>/dev/null || true
    react_to_comment "$COMMENT_ID" "confused"
    touch "$AUTODUCKS_PRE_FAILED_MARKER"
    exit 1
  fi

  # Get the old task numbers out of the discarded tactical zone's YAML
  # block (same extraction pattern as engineer/pre.sh) so post.sh can
  # close the superseded task issues.
  YAML_BLOCK=$(awk '/^```yaml[[:space:]]*$/{flag=1;next}/^```[[:space:]]*$/{flag=0}flag' /tmp/tactical-zone-discard.md)
  if [[ -n "$YAML_BLOCK" ]]; then
    tactical_zone::task_refs "$YAML_BLOCK" > /tmp/architect-dropped-tasks.txt || true
  fi
  touch /tmp/architect-strip-tactical.flag
fi
