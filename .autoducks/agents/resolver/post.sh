#!/usr/bin/env bash
set -euo pipefail
export AUTODUCKS_AGENT="resolver"
source "$(dirname "${BASH_SOURCE[0]}")/../../core/config/load-config.sh"
source "$AUTODUCKS_ROOT/core/feedback/react-to-comment.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-failure.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-skip.sh"
source "$AUTODUCKS_ROOT/core/feedback/progress-labels.sh"
source "$AUTODUCKS_ROOT/core/feedback/status-comment.sh"
source "$AUTODUCKS_ROOT/core/feedback/handle-cancellation.sh"

trap '_rc=$?; notify_failure "$ISSUE_NUM" "$RUN_ID" "" 2>/dev/null || true; \
      status_comment::fail "$ISSUE_NUM" 2>/dev/null || true; \
      react_to_comment "${COMMENT_ID:-}" "confused" 2>/dev/null || true; \
      progress_labels::abort "$ISSUE_NUM" "Resolve:resolving" 2>/dev/null || true; \
      exit $_rc' ERR

# pre.sh has already posted its own comment (failure, or a benign "nothing
# to resolve" skip), reacted, and cleared the progress label — skip all
# checks below so we don't double-notify.
if [[ -f "$AUTODUCKS_PRE_FAILED_MARKER" ]]; then
  rm -f "$AUTODUCKS_PRE_FAILED_MARKER"
  exit 0
fi

cancellation::handle "$ISSUE_NUM" "Resolve:resolving"

if [[ "${LLM_SKIPPED:-}" == "true" ]]; then
  notify_skip "$ISSUE_NUM"
  progress_labels::abort "$ISSUE_NUM" "Resolve:resolving"
  # Do NOT react confused; do NOT call notify_failure.
  exit 0
fi

# Contract check: a full reconciliation with a clean tree, or we bail out
# without touching the branch. `git diff --check` catches leftover conflict
# markers; `--diff-filter=U` catches any path the LLM never touched.
STATUS=""
if [[ -s /tmp/resolution-status ]]; then
  STATUS=$(tr -d '[:space:]' < /tmp/resolution-status)
fi

UNMERGED=$(git diff --name-only --diff-filter=U)
MARKERS_FOUND=false
git diff --check >/dev/null 2>&1 || MARKERS_FOUND=true

if [[ "$STATUS" != "resolved" ]] || [[ -n "$UNMERGED" ]] || [[ "$MARKERS_FOUND" == "true" ]]; then
  git merge --abort 2>/dev/null || true
  export AUTODUCKS_FAIL_CATEGORY="merge-conflict"
  notify_failure "$ISSUE_NUM" "$RUN_ID"
  status_comment::fail "$ISSUE_NUM" "⚠️ Conflicts on PR #$PR_NUM could not be auto-resolved."
  react_to_comment "${COMMENT_ID:-}" "confused"
  progress_labels::abort "$ISSUE_NUM" "Resolve:resolving"
  exit 1
fi

# ── Finalize: commit the resolution and push (never merge, never force) ──
echo "Resolve conflicts on PR #$PR_NUM with base $PR_BASE (autoducks)" > .git/MERGE_MSG
git add -A
git commit --no-edit

# A child-scoped run (CHILD_SLUG set) pushes/labels the child PR under the
# child credential instead of $REPO — re-resolved here rather than carried
# across the pre.sh/post.sh step boundary.
CHILD_SLUG="${CHILD_SLUG:-}"
if [[ -n "$CHILD_SLUG" ]]; then
  CHILD_TOKEN="$(git::resolve_token "$CHILD_SLUG")"
  REPO="$CHILD_SLUG" GH_TOKEN="$CHILD_TOKEN" git::push_branch "$PR_HEAD"
  REPO="$CHILD_SLUG" GH_TOKEN="$CHILD_TOKEN" its::add_label "$PR_NUM" "auto-resolved"
  PR_URL="https://github.com/${CHILD_SLUG}/pull/${PR_NUM}"
else
  git::push_branch "$PR_HEAD"
  its::add_label "$PR_NUM" "auto-resolved"
  PR_URL="https://github.com/${REPO}/pull/${PR_NUM}"
fi

its::comment_issue "$FEATURE_NUM" "$(cat /tmp/resolution-summary.md)"
progress_labels::finish "$ISSUE_NUM" "Resolve:resolving" "Resolve:done"
react_to_comment "${COMMENT_ID:-}" "+1"

status_comment::finish "$ISSUE_NUM" "**Conflicts resolved on PR #$PR_NUM** — review the [pushed merge commit]($PR_URL); the PR is not auto-merged.

_Ran with \`${MODEL:-unknown}\` at effort \`${EFFORT:-unknown}\`._"
