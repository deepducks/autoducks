#!/usr/bin/env bash
set -euo pipefail
export AUTODUCKS_AGENT="reviewer"
source "$(dirname "${BASH_SOURCE[0]}")/../../core/config/load-config.sh"
source "$AUTODUCKS_ROOT/core/feedback/react-to-comment.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-failure.sh"
source "$AUTODUCKS_ROOT/core/feedback/progress-labels.sh"
source "$AUTODUCKS_ROOT/core/feedback/status-comment.sh"
source "$AUTODUCKS_ROOT/core/orchestration/branch-prefix.sh"
source "$AUTODUCKS_ROOT/core/orchestration/parse-waves.sh"

rm -f "$AUTODUCKS_PRE_FAILED_MARKER"
mkdir -p "$AUTODUCKS_MARKER_DIR"

trap '_rc=$?; notify_failure "$ISSUE_NUM" "$RUN_ID" "" 2>/dev/null || true; \
      status_comment::fail "$ISSUE_NUM" 2>/dev/null || true; \
      react_to_comment "${COMMENT_ID:-}" "confused" 2>/dev/null || true; \
      progress_labels::abort "$ISSUE_NUM" "Review:reviewing" 2>/dev/null || true; \
      for _t in "${REVIEW_TARGETS[@]-}"; do \
        [[ -n "$_t" && "$_t" != "$ISSUE_NUM" ]] && progress_labels::abort "$_t" "Review:reviewing" 2>/dev/null || true; \
      done; \
      { [[ -n "${CHECK_RUN_ID:-}" ]] && git::conclude_check_run "$CHECK_RUN_ID" failure "Review failed" "The reviewer agent errored during preparation." 2>/dev/null; } || true; \
      touch "$AUTODUCKS_PRE_FAILED_MARKER"; \
      exit $_rc' ERR

react_to_comment "${COMMENT_ID:-}" "eyes"
status_comment::start "$ISSUE_NUM"

progress_labels::ensure
progress_labels::start "$ISSUE_NUM" "Review:reviewing" "Review:done"

# skip_review REASON — used by every non-fatal "nothing to review" exit below.
# Leaves the run green (no failure notification) while still clearing the
# in-progress label and short-circuiting post.sh via the shared marker.
skip_review() {
  local reason="$1"
  status_comment::finish "$ISSUE_NUM" "**Nothing to review.** $reason"
  react_to_comment "${COMMENT_ID:-}" "+1"
  progress_labels::abort "$ISSUE_NUM" "Review:reviewing"
  { [[ -n "${CHECK_RUN_ID:-}" ]] && git::conclude_check_run "$CHECK_RUN_ID" success "Nothing to review" "$reason" 2>/dev/null; } || true
  touch "$AUTODUCKS_PRE_FAILED_MARKER"
  [[ -n "${GITHUB_OUTPUT:-}" ]] && echo "skip=true" >> "$GITHUB_OUTPUT"
  exit 0
}

# ── Resolve the target PR ──────────────────────────────────────────────
if [[ "${IS_PR:-false}" == "true" ]]; then
  PR_NUM="$ISSUE_NUM"
else
  ISSUE_TITLE=$(its::get_issue "$ISSUE_NUM" | jq -r '.title')
  SLUG=$(git::generate_slug "$ISSUE_NUM" "$ISSUE_TITLE")
  PREFIX=$(branch_prefix_for_issue "$ISSUE_NUM")
  PR_NUM=$(gh pr list --repo "$REPO" --head "$PREFIX/$SLUG" --base "$AUTODUCKS_INTEGRATION_BRANCH" --json number --jq '.[0].number // empty' 2>/dev/null || true)
fi

if [[ -z "$PR_NUM" ]]; then
  skip_review "No open pull request was found for this issue. Run \`$(autoducks_command_for execute)\` to implement it first, then re-run \`$(autoducks_command_for review)\`."
fi

PR_META_JSON=$(git::get_pr "$PR_NUM")
PR_BASE=$(echo "$PR_META_JSON" | jq -r '.baseRefName')
PR_HEAD=$(echo "$PR_META_JSON" | jq -r '.headRefName')
PR_TITLE=$(echo "$PR_META_JSON" | jq -r '.title')
PR_BODY=$(echo "$PR_META_JSON" | jq -r '.body')
PR_STATE=$(echo "$PR_META_JSON" | jq -r '.state')

# ── Emit a GitHub Check-run on the final feature/fix PR ────────────────
# Task PRs reuse the feature/|fix/ head prefix, so the *base* is the reliable
# discriminator: only the final pipeline PR targets the integration branch.
# The check is created in-progress here so every downstream exit — skip,
# failure (ERR trap), or the verdict in post.sh — resolves it; a required
# check that never appeared would otherwise deadlock the PR forever.
CHECK_RUN_ID=""
if [[ "$PR_BASE" == "$AUTODUCKS_INTEGRATION_BRANCH" ]] \
   && { [[ "$PR_HEAD" == feature/* ]] || [[ "$PR_HEAD" == fix/* ]]; }; then
  PR_HEAD_SHA=$(gh pr view "$PR_NUM" --repo "$REPO" --json headRefOid --jq '.headRefOid' 2>/dev/null || true)
  if [[ -n "$PR_HEAD_SHA" ]]; then
    CHECK_RUN_ID=$(git::start_check_run "$AUTODUCKS_REVIEW_CHECK_NAME" "$PR_HEAD_SHA" 2>/dev/null || true)
  fi
fi

# ── Resolve the feature/bug issue this PR implements ───────────────────
if [[ "${IS_PR:-false}" == "true" ]]; then
  FEATURE_NUM=$(resolve_feature_num_from_pr "$PR_HEAD" "$PR_BODY")
else
  FEATURE_NUM="$ISSUE_NUM"
fi

# Mirror set: the feature/bug issue AND its PR both carry the Review label and a
# status comment, so review state is visible from either surface (a user on the
# PR must not re-trigger a review already running from the issue, and vice-versa).
# De-duplicated, empties dropped. ISSUE_NUM is already painted above; add the
# remaining distinct target(s).
REVIEW_TARGETS=()
for _t in "$FEATURE_NUM" "$PR_NUM"; do
  [[ -n "$_t" ]] || continue
  [[ " ${REVIEW_TARGETS[*]-} " == *" $_t "* ]] && continue
  REVIEW_TARGETS+=("$_t")
done

for _t in "${REVIEW_TARGETS[@]}"; do
  [[ "$_t" == "$ISSUE_NUM" ]] && continue   # already painted at the top
  status_comment::start "$_t" 2>/dev/null || true
  progress_labels::start "$_t" "Review:reviewing" "Review:done" 2>/dev/null || true
done

# ── Gather context for the LLM ──────────────────────────────────────────
its::get_issue "$FEATURE_NUM" | jq -r '.title,.body' > /tmp/design-plan.md

# Task acceptance criteria: best-effort — a feature body without a `waves:`
# block (e.g. the single-task fast path) simply yields an empty file.
: > /tmp/task-criteria.md
FEATURE_BODY=$(its::get_issue "$FEATURE_NUM" | jq -r '.body')
if PARSED=$(parse_waves "$FEATURE_BODY" 2>/dev/null); then
  TASK_NUMS=$(echo "$PARSED" | awk -F'|' '$1 == "TASK" {print $3}' | sort -un)
  for t in $TASK_NUMS; do
    its::get_issue "$t" 2>/dev/null \
      | jq -r --arg n "$t" '"## Task #" + $n + " — " + .title + "\n\n" + .body + "\n\n---\n"' \
      >> /tmp/task-criteria.md || true
  done
fi

git::get_pr_diff "$PR_NUM" > /tmp/pr-diff.patch

{
  echo "# PR #$PR_NUM: $PR_TITLE"
  echo ""
  echo "- Base: $PR_BASE"
  echo "- Head: $PR_HEAD"
  echo "- State: $PR_STATE"
  echo ""
  echo "## Changed files"
  echo ""
  gh pr view "$PR_NUM" --repo "$REPO" --json files --jq '.files[].path' | sed 's/^/- /'
} > /tmp/pr-meta.md

# ── Nothing to review: empty diff or the PR is no longer open ──────────
if [[ ! -s /tmp/pr-diff.patch ]]; then
  skip_review "PR #$PR_NUM has an empty diff."
fi
if [[ "$PR_STATE" != "OPEN" ]]; then
  skip_review "PR #$PR_NUM is already \`$PR_STATE\`."
fi

# Share PR state with post.sh (separate GHA step — a fresh process).
export PR_NUM PR_BASE PR_HEAD FEATURE_NUM CHECK_RUN_ID
REVIEW_TARGETS_CSV=$(IFS=,; echo "${REVIEW_TARGETS[*]}")
export REVIEW_TARGETS_CSV
if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "PR_NUM=$PR_NUM" >> "$GITHUB_ENV"
  echo "PR_BASE=$PR_BASE" >> "$GITHUB_ENV"
  echo "PR_HEAD=$PR_HEAD" >> "$GITHUB_ENV"
  echo "FEATURE_NUM=${FEATURE_NUM:-}" >> "$GITHUB_ENV"
  echo "CHECK_RUN_ID=${CHECK_RUN_ID:-}" >> "$GITHUB_ENV"
  echo "REVIEW_TARGETS_CSV=$REVIEW_TARGETS_CSV" >> "$GITHUB_ENV"
fi
