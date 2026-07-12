#!/usr/bin/env bash
set -euo pipefail
export AUTODUCKS_AGENT="reviewer"
source "$(dirname "${BASH_SOURCE[0]}")/../../core/config/load-config.sh"
source "$AUTODUCKS_ROOT/core/feedback/react-to-comment.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-failure.sh"
source "$AUTODUCKS_ROOT/core/feedback/progress-labels.sh"
source "$AUTODUCKS_ROOT/core/feedback/status-comment.sh"
source "$AUTODUCKS_ROOT/core/feedback/handle-cancellation.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-skip.sh"
source "$AUTODUCKS_ROOT/core/orchestration/dispatch-chain.sh"
source "$AUTODUCKS_ROOT/core/orchestration/review-loop.sh"

# The reviewer mirrors progress feedback to both the feature issue and its PR
# when they differ; falls back to the single canonical issue for older
# in-flight runs that don't set REVIEW_TARGETS_CSV.
IFS=',' read -r -a REVIEW_TARGETS <<< "${REVIEW_TARGETS_CSV:-$ISSUE_NUM}"
[[ ${#REVIEW_TARGETS[@]} -eq 0 ]] && REVIEW_TARGETS=("$ISSUE_NUM")

trap '_rc=$?; notify_failure "$ISSUE_NUM" "$RUN_ID" "" 2>/dev/null || true; \
      status_comment::fail "$ISSUE_NUM" 2>/dev/null || true; \
      react_to_comment "${COMMENT_ID:-}" "confused" 2>/dev/null || true; \
      progress_labels::abort "$ISSUE_NUM" "Review:reviewing" 2>/dev/null || true; \
      if [[ -n "${REVIEW_TARGETS[*]-}" ]]; then for _t in "${REVIEW_TARGETS[@]}"; do progress_labels::abort "$_t" "Review:reviewing" 2>/dev/null || true; done; fi; \
      { [[ -n "${CHECK_RUN_ID:-}" ]] && git::conclude_check_run "$CHECK_RUN_ID" failure "Review failed" "The reviewer agent errored before producing a verdict." 2>/dev/null; } || true; \
      exit $_rc' ERR

# pre.sh has already posted its own comment (failure, or a benign "nothing
# to review" skip), reacted, and cleared the progress label — skip all
# checks below so we don't double-notify.
if [[ -f "$AUTODUCKS_PRE_FAILED_MARKER" ]]; then
  rm -f "$AUTODUCKS_PRE_FAILED_MARKER"
  exit 0
fi

cancellation::handle_targets "Review:reviewing" "${CHECK_RUN_ID:-}" "${REVIEW_TARGETS[@]}"

# A validation-skipped LLM run (claude-code-action refused to start on a
# workflow-touching PR) is neither success nor agent failure: report it as
# "not evaluated" and route to the manual /review fallback, without a 😕 or a
# failing Check-run.
if [[ "${LLM_SKIPPED:-}" == "true" ]]; then
  for _t in "${REVIEW_TARGETS[@]}"; do
    notify_skip "$_t"
    progress_labels::abort "$_t" "Review:reviewing"
  done
  { [[ -n "${CHECK_RUN_ID:-}" ]] && git::conclude_check_run "$CHECK_RUN_ID" neutral "Review skipped" "Auto-review unavailable on PRs that modify agent workflows; run /review manually or merge first." 2>/dev/null; } || true
  # Do NOT react confused; do NOT call notify_failure.
  exit 0
fi

# Agent hit its turn limit before producing its output — report the
# max_turns category (with a `turns=<n>` retry hint) rather than
# mislabeling a turn-limit cutoff as scope-missing.
if [[ "${LLM_ERROR_SUBTYPE:-}" == "error_max_turns" ]]; then
  export AUTODUCKS_FAIL_CATEGORY="max_turns" AUTODUCKS_FAIL_PHASE="llm"
  notify_failure "$ISSUE_NUM" "$RUN_ID"
  react_to_comment "${COMMENT_ID:-}" "confused"
  for _t in "${REVIEW_TARGETS[@]}"; do
    status_comment::fail "$_t"
    progress_labels::abort "$_t" "Review:reviewing"
  done
  { [[ -n "${CHECK_RUN_ID:-}" ]] && git::conclude_check_run "$CHECK_RUN_ID" failure "Review incomplete" "The reviewer hit its turn limit before producing a review." 2>/dev/null; } || true
  exit 1
fi

# Check the review was produced
if [[ ! -f /tmp/review.md ]]; then
  export AUTODUCKS_FAIL_CATEGORY="scope-missing"
  notify_failure "$ISSUE_NUM" "$RUN_ID"
  react_to_comment "${COMMENT_ID:-}" "confused"
  for _t in "${REVIEW_TARGETS[@]}"; do
    status_comment::fail "$_t"
    progress_labels::abort "$_t" "Review:reviewing"
  done
  { [[ -n "${CHECK_RUN_ID:-}" ]] && git::conclude_check_run "$CHECK_RUN_ID" failure "Review incomplete" "The reviewer did not produce a review." 2>/dev/null; } || true
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

# Neither `approve` nor `request-changes` is published as its native GitHub
# review event: agent-created PRs are authored by the same PAT identity, and
# GitHub forbids APPROVE/REQUEST_CHANGES on your own PR. The blocking decision
# lives in the Check-run below, which is the actual merge gate.
VERDICT_EVENT="COMMENT"

git::submit_pr_review "$PR_NUM" "$VERDICT_EVENT" /tmp/review.md

# Reflect the verdict on the required Check-run (created by pre.sh on final PRs
# only; CHECK_RUN_ID is empty otherwise). Only `request-changes` blocks the
# merge — `approve`/`comment` conclude success so the gate stays advisory.
if [[ -n "${CHECK_RUN_ID:-}" ]]; then
  if [[ "$VERDICT" == "request-changes" ]]; then
    git::conclude_check_run "$CHECK_RUN_ID" failure "Reviewer: request changes" "The reviewer requested changes on PR #$PR_NUM." || true
  else
    git::conclude_check_run "$CHECK_RUN_ID" success "Reviewer: $VERDICT" "The reviewer did not block PR #$PR_NUM." || true
  fi
fi

if [[ "$VERDICT" == "request-changes" ]]; then
  done_label="Review:changes"
else
  done_label="Review:done"
fi
for _t in "${REVIEW_TARGETS[@]}"; do
  progress_labels::finish "$_t" "Review:reviewing" "$done_label"
done

# Bounded self-continuing loop: on request-changes, auto-dispatch a rework
# round instead of waiting on a human /rework, up to review.max_iterations.
# auto_rework:false cleanly restores the human-gated flow below.
#
# Idempotency guard: a duplicate ready_for_review event / manual re-trigger
# re-reviews the same PR_HEAD_SHA the current marker was already recorded
# for — that's this exact round already dispatched, not a new one, so it's
# a no-op rather than a second increment + dispatch. No workflow-local
# state: the comparison is entirely against the marker comment already on
# the PR (review_loop::sha). When PR_HEAD_SHA is empty (pre.sh's `gh pr
# view` transiently failed to resolve it), there's nothing to compare
# against — fall back to review_loop::already_dispatched's SHA-less signals
# instead of falling straight through to a second increment + dispatch.
AUTO_REWORK_FOOTER=""
if [[ "$VERDICT" == "request-changes" && "$AUTODUCKS_REVIEW_AUTO_REWORK" == "true" ]]; then
  review_loop_iteration=$(review_loop::iteration "$FEATURE_NUM" "$PR_NUM")
  review_loop_prev_sha=$(review_loop::sha "$FEATURE_NUM" "$PR_NUM")
  case "$(review_loop::decide "$VERDICT" "$review_loop_iteration" "$AUTODUCKS_REVIEW_MAX_ITERATIONS")" in
    continue)
      if [[ -n "$review_loop_prev_sha" && -n "${PR_HEAD_SHA:-}" && "$review_loop_prev_sha" == "$PR_HEAD_SHA" ]]; then
        AUTO_REWORK_FOOTER="🔁 Auto-rework round ${review_loop_iteration}/${AUTODUCKS_REVIEW_MAX_ITERATIONS} already dispatched for this commit — skipping duplicate."
      elif [[ -z "${PR_HEAD_SHA:-}" ]] && review_loop::already_dispatched "$FEATURE_NUM" "$PR_NUM" "$review_loop_iteration"; then
        AUTO_REWORK_FOOTER="🔁 Auto-rework round ${review_loop_iteration}/${AUTODUCKS_REVIEW_MAX_ITERATIONS} already dispatched — skipping duplicate."
      else
        review_loop::record "$FEATURE_NUM" "$PR_NUM" "$((review_loop_iteration + 1))" "" "${PR_HEAD_SHA:-}"
        # Headless rework dispatch — actor carried forward for the D15 assignee.
        git::dispatch_workflow autoducks-rework.yml \
          -f pr_number="$PR_NUM" \
          -f actor="${COMMENTER:-}" \
          ${OVERRIDE_MODEL:+-f model="$OVERRIDE_MODEL"} ${OVERRIDE_EFFORT:+-f effort="$OVERRIDE_EFFORT"}
        AUTO_REWORK_FOOTER="🔁 Auto-rework round $((review_loop_iteration + 1))/${AUTODUCKS_REVIEW_MAX_ITERATIONS} dispatched."
      fi
      ;;
    stop-blocked-max)
      AUTO_REWORK_FOOTER="⚠️ Reached max review iterations (${AUTODUCKS_REVIEW_MAX_ITERATIONS}) — stopping automatic rework."
      ;;
  esac
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
    if [[ "$AUTO_REWORK_FOOTER" == "🔁"* ]]; then
      NEXT="**Next:** $AUTO_REWORK_FOOTER"
    else
      NEXT="**Next:** run \`$(autoducks_command_for rework)\` to address the findings on this PR now,
or \`$(autoducks_command_for defer)\` to save them as a follow-up issue and merge as-is."
      [[ -n "$AUTO_REWORK_FOOTER" ]] && NEXT="$NEXT

$AUTO_REWORK_FOOTER"
    fi
    ;;
  *)
    HEADLINE="💬 **Review: comment**"
    NEXT="**Next:** run \`$(autoducks_command_for rework)\` to address the findings on this PR now,
or \`$(autoducks_command_for defer)\` to save them as a follow-up issue and merge as-is."
    ;;
esac

for _t in "${REVIEW_TARGETS[@]}"; do
  status_comment::finish "$_t" "$HEADLINE — see the [PR review]($PR_URL) on #$PR_NUM.

$NEXT

_Ran with \`${MODEL:-unknown}\` at effort \`${EFFORT:-unknown}\`._"
done

# #auto: chain — hand off to the next queued agent, if any.
chain::dispatch_next "${AUTO_CHAIN:-}" "$ISSUE_NUM"
