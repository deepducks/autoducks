#!/usr/bin/env bash
set -euo pipefail
export AUTODUCKS_AGENT="architect"
source "$(dirname "${BASH_SOURCE[0]}")/../../core/config/load-config.sh"
source "$AUTODUCKS_ROOT/core/feedback/react-to-comment.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-failure.sh"
source "$AUTODUCKS_ROOT/core/feedback/progress-labels.sh"
source "$AUTODUCKS_ROOT/core/feedback/status-comment.sh"
source "$AUTODUCKS_ROOT/core/orchestration/tactical-zone.sh"
source "$AUTODUCKS_ROOT/core/orchestration/dispatch-chain.sh"

trap '_rc=$?; notify_failure "$ISSUE_NUM" "$RUN_ID" "" 2>/dev/null || true; \
      status_comment::fail "$ISSUE_NUM" 2>/dev/null || true; \
      react_to_comment "${COMMENT_ID:-}" "confused" 2>/dev/null || true; \
      progress_labels::abort "$ISSUE_NUM" "Design:draft" 2>/dev/null || true; \
      exit $_rc' ERR

# pre.sh has already posted its own failure comment, reacted, and aborted the
# progress label (via its ERR trap or an explicit exit) — skip all checks so
# we don't double-notify.
if [[ -f /tmp/autoducks-pre-failed ]]; then
  rm -f /tmp/autoducks-pre-failed
  exit 0
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

# Update issue body with design spec, preserving the tactical zone if one
# was stashed by pre.sh
if [[ -f /tmp/tactical-zone-preserved.flag ]]; then
  # Guard: flag set but content file vanished => lost state between steps.
  # An empty-but-present file is valid and must NOT trip this.
  if [[ ! -f /tmp/tactical-zone-preserved.md ]]; then
    its::comment_issue "$ISSUE_NUM" "❌ Aborting \`$(autoducks_command_for architect)\`: the preserved tactical zone went missing between steps. Publishing would wipe the tactical plan, so no changes were made. Re-run \`$(autoducks_command_for architect)\`."
    status_comment::fail "$ISSUE_NUM"
    react_to_comment "$COMMENT_ID" "confused"
    progress_labels::abort "$ISSUE_NUM" "Design:draft"
    exit 1
  fi
  assemble_body /tmp/design-spec.md /tmp/tactical-zone-preserved.md /tmp/feature-body.md
  its::update_issue_body "$ISSUE_NUM" /tmp/feature-body.md
else
  its::update_issue_body "$ISSUE_NUM" /tmp/design-spec.md
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
gh label create "Bug" --repo "$REPO" --color "D73A4A" --description "Autoducks bug pipeline" 2>/dev/null || true
its::add_label "$ISSUE_NUM" "$ISSUE_KIND"
if [[ "$ISSUE_KIND" == "Bug" ]]; then
  its::remove_label "$ISSUE_NUM" "Feature" 2>/dev/null || true
else
  its::remove_label "$ISSUE_NUM" "Bug" 2>/dev/null || true
fi

# Remove Draft label if present
its::remove_label "$ISSUE_NUM" "Draft" 2>/dev/null || true

progress_labels::finish "$ISSUE_NUM" "Design:draft" "Design:done"

# Done-assignee (D15): the command author owns the next action.
its::assign_issue "$ISSUE_NUM" "${COMMENTER:-}" 2>/dev/null || true

react_to_comment "$COMMENT_ID" "+1"

status_comment::finish "$ISSUE_NUM" "**Design complete** (classified as \`${ISSUE_KIND}\`).

The issue body now holds the full design — problem statement, proposed
solution, technical design, dependencies, constraints, and out-of-scope notes.
Review and edit anything you'd like to steer before planning.

**Next:** run \`$(autoducks_command_for engineer)\` to break the design into a tactical plan and task issues.

_Ran with \`${MODEL:-unknown}\` at effort \`${EFFORT:-unknown}\`._"

# #auto: chain — hand off to the next queued agent, if any.
chain::dispatch_next "${AUTO_CHAIN:-}" "$ISSUE_NUM"
