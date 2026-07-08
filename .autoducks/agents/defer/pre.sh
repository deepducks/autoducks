#!/usr/bin/env bash
set -euo pipefail
export AUTODUCKS_AGENT="defer"
source "$(dirname "${BASH_SOURCE[0]}")/../../core/config/load-config.sh"
source "$AUTODUCKS_ROOT/core/feedback/react-to-comment.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-failure.sh"
source "$AUTODUCKS_ROOT/core/feedback/status-comment.sh"
source "$AUTODUCKS_ROOT/core/orchestration/branch-prefix.sh"

rm -f "$AUTODUCKS_PRE_FAILED_MARKER"
mkdir -p "$AUTODUCKS_MARKER_DIR"

trap '_rc=$?; notify_failure "$ISSUE_NUM" "$RUN_ID" "" 2>/dev/null || true; \
      status_comment::fail "$ISSUE_NUM" 2>/dev/null || true; \
      react_to_comment "${COMMENT_ID:-}" "confused" 2>/dev/null || true; \
      touch "$AUTODUCKS_PRE_FAILED_MARKER"; \
      exit $_rc' ERR

# skip_defer REASON — used by every non-fatal "nothing to defer" exit below.
# Leaves the run green (no failure notification) while still short-circuiting
# post.sh via the shared marker.
skip_defer() {
  local reason="$1"
  status_comment::finish "$ISSUE_NUM" "**Nothing to defer.** $reason"
  react_to_comment "${COMMENT_ID:-}" "+1"
  touch "$AUTODUCKS_PRE_FAILED_MARKER"
  [[ -n "${GITHUB_OUTPUT:-}" ]] && echo "skip=true" >> "$GITHUB_OUTPUT"
  exit 0
}

react_to_comment "${COMMENT_ID:-}" "eyes"
status_comment::start "$ISSUE_NUM"

# ── Resolve the target PR ────────────────────────────────────────────────
# Deferring is deliberately allowed on closed/merged PRs (unlike the
# Reviewer, which skips outright) — the whole point is to capture feedback
# so the user can merge/close the PR without waiting on a re-review.
if [[ "${IS_PR:-false}" == "true" ]]; then
  PR_NUM="$ISSUE_NUM"
else
  ISSUE_TITLE=$(its::get_issue "$ISSUE_NUM" | jq -r '.title')
  SLUG=$(git::generate_slug "$ISSUE_NUM" "$ISSUE_TITLE")
  PREFIX=$(branch_prefix_for_issue "$ISSUE_NUM")
  PR_NUM=$(gh pr list --repo "$REPO" --head "$PREFIX/$SLUG" --base "$AUTODUCKS_INTEGRATION_BRANCH" --state all --json number --jq '.[0].number // empty' 2>/dev/null || true)
fi

if [[ -z "$PR_NUM" ]]; then
  skip_defer "No pull request was found for this issue. Run \`$(autoducks_command_for execute)\` to implement it first."
fi

PR_META_JSON=$(git::get_pr "$PR_NUM")
PR_TITLE=$(echo "$PR_META_JSON" | jq -r '.title')
PR_BODY=$(echo "$PR_META_JSON" | jq -r '.body')
PR_STATE=$(echo "$PR_META_JSON" | jq -r '.state')

# ── Resolve the feature/bug issue this PR implements ────────────────────
if [[ "${IS_PR:-false}" == "true" ]]; then
  FEATURE_NUM=$(resolve_feature_num_from_pr \
    "$(echo "$PR_META_JSON" | jq -r '.headRefName')" "$PR_BODY")
else
  FEATURE_NUM="$ISSUE_NUM"
fi

# ── Gather review feedback (read-only; PR need not be open) ─────────────
git::list_pr_reviews "$PR_NUM" > /tmp/defer-reviews.json
its::list_comments "$PR_NUM" > /tmp/defer-comments.json

REVIEW_COUNT=$(jq 'length' /tmp/defer-reviews.json 2>/dev/null || echo 0)
COMMENT_COUNT=$(jq 'length' /tmp/defer-comments.json 2>/dev/null || echo 0)

# ── DoR: there must be actual reviewer/human feedback to defer ──────────
if [[ "$REVIEW_COUNT" -eq 0 && "$COMMENT_COUNT" -eq 0 ]]; then
  rm -f /tmp/defer-reviews.json /tmp/defer-comments.json
  skip_defer "PR #$PR_NUM has no reviewer or human feedback to capture."
fi

# ── Idempotency guard: reuse an already-open deferral issue for this
# (feature, PR) pair instead of creating a duplicate. No dedicated label —
# the marker text itself is the search key. ─────────────────────────────
EXISTING_DEFER_NUM=$(gh issue list --repo "$REPO" --state open \
  --search "\"autoducks:deferred-from: pr=$PR_NUM feature=$FEATURE_NUM\" in:body" \
  --json number --jq '.[0].number // empty' 2>/dev/null || true)

# ── Write context for the LLM ────────────────────────────────────────────
its::get_issue "$FEATURE_NUM" | jq -r '.title,.body' > /tmp/design-plan.md

{
  echo "# Review feedback for PR #$PR_NUM: $PR_TITLE"
  echo ""
  echo "- State: $PR_STATE"
  echo ""
  echo "## Reviews and inline review-thread comments"
  echo ""
  jq -r '.[] | "### " + (.author // "unknown") + (if .path then " (" + .path + (if .line then ":" + (.line|tostring) else "" end) + ")" else "" end) + "\n\n" + .body + "\n\n---\n"' /tmp/defer-reviews.json
  echo "## Conversation comments"
  echo ""
  jq -r '.[] | "### " + (.author // "unknown") + "\n\n" + .body + "\n\n---\n"' /tmp/defer-comments.json
} > /tmp/defer-context.md

rm -f /tmp/defer-reviews.json /tmp/defer-comments.json

# Share PR/feature/idempotency state with post.sh (separate GHA step — a
# fresh process).
export PR_NUM FEATURE_NUM EXISTING_DEFER_NUM
if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "PR_NUM=$PR_NUM" >> "$GITHUB_ENV"
  echo "FEATURE_NUM=${FEATURE_NUM:-}" >> "$GITHUB_ENV"
  echo "EXISTING_DEFER_NUM=${EXISTING_DEFER_NUM:-}" >> "$GITHUB_ENV"
fi
