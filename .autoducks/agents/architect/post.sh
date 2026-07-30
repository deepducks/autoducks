#!/usr/bin/env bash
set -euo pipefail
export AUTODUCKS_AGENT="architect"
source "$(dirname "${BASH_SOURCE[0]}")/../../core/config/load-config.sh"
source "$AUTODUCKS_ROOT/core/feedback/react-to-comment.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-failure.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-skip.sh"
source "$AUTODUCKS_ROOT/core/feedback/progress-labels.sh"
source "$AUTODUCKS_ROOT/core/feedback/status-comment.sh"
source "$AUTODUCKS_ROOT/core/feedback/handle-cancellation.sh"
source "$AUTODUCKS_ROOT/core/orchestration/tactical-zone.sh"
source "$AUTODUCKS_ROOT/core/orchestration/dispatch-chain.sh"
source "$AUTODUCKS_ROOT/core/orchestration/design-sections.sh"
source "$AUTODUCKS_ROOT/core/config/classify-label.sh"

trap '_rc=$?; notify_failure "$ISSUE_NUM" "$RUN_ID" "" 2>/dev/null || true; \
      status_comment::fail "$ISSUE_NUM" 2>/dev/null || true; \
      react_to_comment "${COMMENT_ID:-}" "confused" 2>/dev/null || true; \
      progress_labels::abort "$ISSUE_NUM" "Design:draft" 2>/dev/null || true; \
      exit $_rc' ERR

# pre.sh has already posted its own failure comment, reacted, and aborted the
# progress label (via its ERR trap or an explicit exit) — skip all checks so
# we don't double-notify.
if [[ -f "$AUTODUCKS_PRE_FAILED_MARKER" ]]; then
  rm -f "$AUTODUCKS_PRE_FAILED_MARKER"
  exit 0
fi

cancellation::handle "$ISSUE_NUM" "Design:draft"

if [[ "${LLM_SKIPPED:-}" == "true" ]]; then
  notify_skip "$ISSUE_NUM"
  progress_labels::abort "$ISSUE_NUM" "Design:draft"
  # Do NOT react confused; do NOT call notify_failure.
  exit 0
fi

# Agent hit its turn limit before producing its output — report the
# max_turns category (with a `turns=<n>` retry hint) rather than
# mislabeling a turn-limit cutoff as scope-missing.
if [[ "${LLM_ERROR_SUBTYPE:-}" == "error_max_turns" ]]; then
  export AUTODUCKS_FAIL_CATEGORY="max_turns" AUTODUCKS_FAIL_PHASE="llm"
  notify_failure "$ISSUE_NUM" "$RUN_ID"
  status_comment::fail "$ISSUE_NUM"
  react_to_comment "$COMMENT_ID" "confused"
  progress_labels::abort "$ISSUE_NUM" "Design:draft"
  exit 1
fi

# Check design spec was produced
if [[ ! -f /tmp/design-spec.md ]]; then
  export AUTODUCKS_FAIL_CATEGORY="scope-missing"
  notify_failure "$ISSUE_NUM" "$RUN_ID"
  status_comment::fail "$ISSUE_NUM"
  react_to_comment "$COMMENT_ID" "confused"
  progress_labels::abort "$ISSUE_NUM" "Design:draft"
  exit 1
fi

# Publish the design-only body. Any prior tactical zone is stripped — the
# design has changed, so the old plan is torn down below rather than
# re-emitted verbatim. Wrap the six canonical sections in markers first so
# downstream agents can extract them individually (design_sections::extract).
design_sections::wrap /tmp/design-spec.md /tmp/design-body.md
its::update_issue_body "$ISSUE_NUM" /tmp/design-body.md

if [[ -f /tmp/architect-strip-tactical.flag ]]; then
  # Close child task issues named in the discarded plan.
  if [[ -s /tmp/architect-dropped-tasks.txt ]]; then
    while read -r old; do
      [[ -n "$old" ]] || continue
      its::close_issue "$old" \
        "Superseded by a design revision on #$ISSUE_NUM — re-run \`$(autoducks_command_for engineer)\` to regenerate the plan." \
        "not_planned" || true
    done < /tmp/architect-dropped-tasks.txt
  fi
  ARCHITECT_STRIPPED=1
fi

# The published body is design-only, so any completed tactical plan is now
# invalidated — drop its routing/revision labels. Driven by the presence check
# recorded in pre.sh, NOT by the tactical-strip flag, so the label never lingers
# even when the old body's markers were missing or damaged. Idempotent and only
# emits calls for labels that were actually present (keeps first-design runs
# from touching Tactics:* labels).
if [[ -s /tmp/architect-clear-tactics.flag ]]; then
  while IFS= read -r _lbl; do
    [[ -n "$_lbl" ]] || continue
    its::remove_label "$ISSUE_NUM" "$_lbl" 2>/dev/null || true
  done < /tmp/architect-clear-tactics.flag
fi

# Issue classification (D10): the LLM writes "Feature" or "Bug" to
# /tmp/issue-type. Anything else (or a missing file) falls back to Feature.
ISSUE_KIND="Feature"
if [[ -s /tmp/issue-type ]]; then
  _kind=$(tr -d '[:space:]' < /tmp/issue-type)
  case "$_kind" in
    Bug|bug)         ISSUE_KIND="Bug" ;;
    Feature|feature) ISSUE_KIND="Feature" ;;
  esac
fi

# Route-critical: the label makes routing work on every repo kind.
# Type is best-effort (org-only feature — silently no-ops on user repos).
its::set_issue_type "$ISSUE_NUM" "$ISSUE_KIND" 2>/dev/null || true
classify_label::apply "$ISSUE_NUM" "$ISSUE_KIND"

# Remove Draft label if present
its::remove_label "$ISSUE_NUM" "Draft" 2>/dev/null || true

progress_labels::finish "$ISSUE_NUM" "Design:draft" "Design:done"

# Done-assignee (D15): the command author owns the next action.
its::assign_issue "$ISSUE_NUM" "${COMMENTER:-}" 2>/dev/null || true

react_to_comment "$COMMENT_ID" "+1"

FINISH_MSG="**Design complete** (classified as \`${ISSUE_KIND}\`).

The issue body now holds the full design — problem statement, proposed
solution, technical design, dependencies, constraints, and out-of-scope notes.
Review and edit anything you'd like to steer before planning.

**Next:** run \`$(autoducks_command_for engineer)\` to break the design into a tactical plan and task issues.

_Ran with \`${MODEL:-unknown}\` at effort \`${EFFORT:-unknown}\`._"

if [[ "${ARCHITECT_STRIPPED:-0}" == "1" ]]; then
  DROPPED_NUMBERS=""
  if [[ -s /tmp/architect-dropped-tasks.txt ]]; then
    DROPPED_NUMBERS=$(sed 's/^/#/' /tmp/architect-dropped-tasks.txt | paste -sd, - | sed 's/,/, /g')
  fi
  FINISH_MSG="$FINISH_MSG

⚠️ **The previous tactical plan was removed.** Because the design changed, the old plan and its task issues (\`${DROPPED_NUMBERS}\`) were discarded to keep them from going stale. **Re-run \`$(autoducks_command_for engineer)\`** to regenerate the plan before executing."
fi

status_comment::finish "$ISSUE_NUM" "$FINISH_MSG"

# #auto: chain — hand off to the next queued agent, if any.
chain::dispatch_next "${AUTO_CHAIN:-}" "$ISSUE_NUM"
