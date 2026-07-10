#!/usr/bin/env bash
set -euo pipefail
export AUTODUCKS_AGENT="defer"
source "$(dirname "${BASH_SOURCE[0]}")/../../core/config/load-config.sh"
source "$AUTODUCKS_ROOT/core/feedback/react-to-comment.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-failure.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-skip.sh"
source "$AUTODUCKS_ROOT/core/feedback/status-comment.sh"
source "$AUTODUCKS_ROOT/core/feedback/handle-cancellation.sh"

trap '_rc=$?; notify_failure "$ISSUE_NUM" "$RUN_ID" "" 2>/dev/null || true; \
      status_comment::fail "$ISSUE_NUM" 2>/dev/null || true; \
      react_to_comment "${COMMENT_ID:-}" "confused" 2>/dev/null || true; \
      exit $_rc' ERR

# pre.sh has already posted its own comment (failure, or a benign "nothing
# to defer" skip), reacted, and short-circuited via the shared marker.
if [[ -f "$AUTODUCKS_PRE_FAILED_MARKER" ]]; then
  rm -f "$AUTODUCKS_PRE_FAILED_MARKER"
  exit 0
fi

# defer clears no in-progress label — pass an empty label so the helper
# skips the abort and only handles the neutral status comment + exit.
cancellation::handle "$ISSUE_NUM" ""

if [[ "${LLM_SKIPPED:-}" == "true" ]]; then
  notify_skip "$ISSUE_NUM"
  # defer clears no in-progress label — nothing to abort.
  # Do NOT react confused; do NOT call notify_failure.
  exit 0
fi

# The LLM judged there was nothing substantive worth deferring — green skip,
# no issue created.
if [[ -f /tmp/defer-none.md ]]; then
  status_comment::finish "$ISSUE_NUM" "**Nothing to defer.** $(cat /tmp/defer-none.md)"
  react_to_comment "${COMMENT_ID:-}" "+1"
  exit 0
fi

# Agent hit its turn limit before producing its output — report the
# max_turns category (with a `turns=<n>` retry hint) rather than
# mislabeling a turn-limit cutoff as scope-missing.
if [[ "${LLM_ERROR_SUBTYPE:-}" == "error_max_turns" ]]; then
  export AUTODUCKS_FAIL_CATEGORY="max_turns" AUTODUCKS_FAIL_PHASE="llm"
  notify_failure "$ISSUE_NUM" "$RUN_ID"
  status_comment::fail "$ISSUE_NUM"
  react_to_comment "${COMMENT_ID:-}" "confused"
  exit 1
fi

if [[ ! -f /tmp/defer-issue.md ]]; then
  export AUTODUCKS_FAIL_CATEGORY="scope-missing"
  notify_failure "$ISSUE_NUM" "$RUN_ID"
  status_comment::fail "$ISSUE_NUM"
  react_to_comment "${COMMENT_ID:-}" "confused"
  exit 1
fi

FEEDBACK_COUNT=$(grep -c '^### ' /tmp/defer-context.md 2>/dev/null || true)
FEEDBACK_COUNT="${FEEDBACK_COUNT:-0}"

# Idempotency marker + back-link, prepended ahead of the LLM's body.
MARKER="<!-- autoducks:deferred-from: pr=$PR_NUM feature=$FEATURE_NUM -->"
{
  echo "$MARKER"
  echo ""
  echo "Related to #$FEATURE_NUM."
  echo ""
  cat /tmp/defer-issue.md
} > /tmp/defer-issue-final.md

if [[ -n "${EXISTING_DEFER_NUM:-}" ]]; then
  its::update_issue_body "$EXISTING_DEFER_NUM" /tmp/defer-issue-final.md
  DEFER_ISSUE_NUM="$EXISTING_DEFER_NUM"
else
  DEFER_ISSUE_NUM=$(its::create_issue "Follow-up: deferred review of #$FEATURE_NUM (PR #$PR_NUM)" /tmp/defer-issue-final.md "" "" "")
fi

react_to_comment "${COMMENT_ID:-}" "+1"

status_comment::finish "$ISSUE_NUM" "Deferred $FEEDBACK_COUNT review comments to #$DEFER_ISSUE_NUM — merge/close this PR safely; run \`$(autoducks_command_for architect)\` on #$DEFER_ISSUE_NUM when you're ready.

_Ran with \`${MODEL:-unknown}\` at effort \`${EFFORT:-unknown}\`._"
