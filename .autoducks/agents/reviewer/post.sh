#!/usr/bin/env bash
set -euo pipefail
export AUTODUCKS_AGENT="reviewer"
source "$(dirname "${BASH_SOURCE[0]}")/../../core/config/load-config.sh"
source "$AUTODUCKS_ROOT/core/feedback/react-to-comment.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-failure.sh"
source "$AUTODUCKS_ROOT/core/feedback/progress-labels.sh"
source "$AUTODUCKS_ROOT/core/feedback/status-comment.sh"
source "$AUTODUCKS_ROOT/core/orchestration/dispatch-chain.sh"

trap '_rc=$?; notify_failure "$ISSUE_NUM" "$RUN_ID" "" 2>/dev/null || true; \
      status_comment::fail "$ISSUE_NUM" 2>/dev/null || true; \
      react_to_comment "${COMMENT_ID:-}" "confused" 2>/dev/null || true; \
      progress_labels::abort "$ISSUE_NUM" "Review:reviewing" 2>/dev/null || true; \
      exit $_rc' ERR

# pre.sh has already posted its own comment (failure, or a benign "nothing
# to review" skip), reacted, and cleared the progress label — skip all
# checks below so we don't double-notify.
if [[ -f /tmp/autoducks-pre-failed ]]; then
  rm -f /tmp/autoducks-pre-failed
  exit 0
fi

# Check the review was produced
if [[ ! -f /tmp/review.md ]]; then
  export AUTODUCKS_FAIL_CATEGORY="scope-missing"
  notify_failure "$ISSUE_NUM" "$RUN_ID"
  status_comment::fail "$ISSUE_NUM"
  react_to_comment "${COMMENT_ID:-}" "confused"
  progress_labels::abort "$ISSUE_NUM" "Review:reviewing"
  exit 1
fi

# Verdict contract: exactly one of approve|comment|request-changes. Missing
# or garbage falls back to the conservative middle ground, `comment`.
VERDICT="comment"
if [[ -s /tmp/review-verdict ]]; then
  _v=$(tr -d '[:space:]' < /tmp/review-verdict)
  case "$_v" in
    approve|comment|request-changes) VERDICT="$_v" ;;
  esac
fi

# `approve` is never published as a GitHub APPROVE event — the bot review is
# informational, never a formal (required-check-counting) approval.
if [[ "$VERDICT" == "request-changes" ]]; then
  VERDICT_EVENT="REQUEST_CHANGES"
else
  VERDICT_EVENT="COMMENT"
fi

git::submit_pr_review "$PR_NUM" "$VERDICT_EVENT" /tmp/review.md

if [[ "$VERDICT" == "request-changes" ]]; then
  progress_labels::finish "$ISSUE_NUM" "Review:reviewing" "Review:changes"
else
  progress_labels::finish "$ISSUE_NUM" "Review:reviewing" "Review:done"
fi

react_to_comment "${COMMENT_ID:-}" "+1"

PR_URL="https://github.com/${REPO}/pull/${PR_NUM}"
case "$VERDICT" in
  approve)
    HEADLINE="✅ **Review: approve**"
    NEXT="**Next:** merge PR #$PR_NUM when you're ready — the bot review is informational only (posted as a comment, not a formal approval)."
    ;;
  request-changes)
    HEADLINE="🔴 **Review: request changes**"
    NEXT="**Next:** run \`$(autoducks_command_for rework)\` to address the findings on this PR now,
or \`$(autoducks_command_for defer)\` to save them as a follow-up issue and merge as-is."
    ;;
  *)
    HEADLINE="💬 **Review: comment**"
    NEXT="**Next:** run \`$(autoducks_command_for rework)\` to address the findings on this PR now,
or \`$(autoducks_command_for defer)\` to save them as a follow-up issue and merge as-is."
    ;;
esac

status_comment::finish "$ISSUE_NUM" "$HEADLINE — see the [PR review]($PR_URL) on #$PR_NUM.

$NEXT

_Ran with \`${MODEL:-unknown}\` at effort \`${EFFORT:-unknown}\`._"

# #auto: chain — hand off to the next queued agent, if any.
chain::dispatch_next "${AUTO_CHAIN:-}" "$ISSUE_NUM"
