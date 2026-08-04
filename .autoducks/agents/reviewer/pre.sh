#!/usr/bin/env bash
set -euo pipefail
export AUTODUCKS_AGENT="reviewer"
source "$(dirname "${BASH_SOURCE[0]}")/../../core/config/load-config.sh"
source "$AUTODUCKS_ROOT/core/feedback/react-to-comment.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-failure.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-skip.sh"
source "$AUTODUCKS_ROOT/core/feedback/progress-labels.sh"
source "$AUTODUCKS_ROOT/core/feedback/status-comment.sh"
source "$AUTODUCKS_ROOT/core/orchestration/branch-prefix.sh"
source "$AUTODUCKS_ROOT/core/context/resolve-context.sh"

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
  react_to_comment "${COMMENT_ID:-}" "+1"

  # Teardown covers the full mirror set once it's been built (empty-diff /
  # closed-PR skips at L168/L171); at the early no-PR skip (L58) REVIEW_TARGETS
  # is not yet populated and only $ISSUE_NUM was painted — fall back to it.
  local _targets
  if [[ -n "${REVIEW_TARGETS[*]-}" ]]; then
    _targets=("${REVIEW_TARGETS[@]}")
  else
    _targets=("$ISSUE_NUM")
  fi

  local _t
  for _t in "${_targets[@]}"; do
    status_comment::finish "$_t" "**Nothing to review.** $reason"
    progress_labels::abort "$_t" "Review:reviewing"
  done

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
# PR_HEAD_SHA also feeds the review-loop duplicate-event guard in post.sh
# (review_loop::sha), so it's resolved unconditionally, not just on the
# final feature/fix → integration-branch PRs that get a Check-run.
PR_HEAD_SHA=$(gh pr view "$PR_NUM" --repo "$REPO" --json headRefOid --jq '.headRefOid' 2>/dev/null || true)
if [[ "$PR_BASE" == "$AUTODUCKS_INTEGRATION_BRANCH" ]] \
   && { [[ "$PR_HEAD" == feature/* ]] || [[ "$PR_HEAD" == fix/* ]]; } \
   && [[ -n "$PR_HEAD_SHA" ]]; then
  CHECK_RUN_ID=$(git::start_check_run "$AUTODUCKS_REVIEW_CHECK_NAME" "$PR_HEAD_SHA" 2>/dev/null || true)
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

# ── Metarepo: make submodule objects available for the expanded diff ────
# git::get_pr_diff (used by resolve_context) runs `git diff --submodule=diff`
# so the reviewer sees real per-file child code instead of `-Subproject commit`
# gitlink lines. That needs each child's objects for BOTH the base and head
# sides present locally, so fetch all child branches (best-effort).
if metarepo::enabled; then
  git fetch origin "$PR_BASE" "$PR_HEAD" 2>/dev/null || true
  git submodule sync --recursive 2>/dev/null || true
  git submodule update --init --recursive 2>/dev/null || true
  git submodule foreach --recursive \
    'git fetch origin "+refs/heads/*:refs/remotes/origin/*" 2>/dev/null || true' 2>/dev/null || true
fi

# ── Gather context for the LLM ──────────────────────────────────────────
resolve_context "reviewer" "$PR_NUM" "$FEATURE_NUM"

# Direct gh call (outside the resolver surface): the changed-files list is
# needed here for the workflow-touching short-circuit below.
PR_CHANGED_FILES=$(gh pr view "$PR_NUM" --repo "$REPO" --json files --jq '.files[].path')

# ── Layer 3: pre-detection short-circuit for workflow-touching PRs ─────
# claude-code-action refuses to execute against repository secrets on PRs
# that modify agent workflow files (an anti-tampering safeguard) — post.sh's
# LLM_SKIPPED guard (Layer 1) catches this too, but only after burning an LLM
# invocation. Detect it here instead, before the LLM step even runs. Only the
# automatic `pull_request` trigger is affected — a human explicitly running
# `/review` via `issue_comment` is not subject to this validation.
if [[ "${EVENT_NAME:-}" == "pull_request" ]] \
   && grep -qE '^\.github/workflows/autoducks-[^/]+\.yml$' <<< "$PR_CHANGED_FILES"; then
  for _t in "${REVIEW_TARGETS[@]}"; do
    notify_skip "$_t"
    progress_labels::abort "$_t" "Review:reviewing"
  done
  { [[ -n "${CHECK_RUN_ID:-}" ]] && git::conclude_check_run "$CHECK_RUN_ID" neutral "Review skipped" "Auto-review unavailable on PRs that modify agent workflows; run /review manually or merge first." 2>/dev/null; } || true
  touch "$AUTODUCKS_PRE_FAILED_MARKER"
  [[ -n "${GITHUB_OUTPUT:-}" ]] && echo "skip=true" >> "$GITHUB_OUTPUT"
  exit 0
fi

# ── Nothing to review: empty diff or the PR is no longer open ──────────
if [[ ! -s /tmp/pr-diff.patch ]]; then
  skip_review "PR #$PR_NUM has an empty diff."
fi
if [[ "$PR_STATE" != "OPEN" ]]; then
  skip_review "PR #$PR_NUM is already \`$PR_STATE\`."
fi

# Share PR state with post.sh (separate GHA step — a fresh process).
export PR_NUM PR_BASE PR_HEAD PR_HEAD_SHA FEATURE_NUM CHECK_RUN_ID
REVIEW_TARGETS_CSV=$(IFS=,; echo "${REVIEW_TARGETS[*]}")
export REVIEW_TARGETS_CSV
if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "PR_NUM=$PR_NUM" >> "$GITHUB_ENV"
  echo "PR_BASE=$PR_BASE" >> "$GITHUB_ENV"
  echo "PR_HEAD=$PR_HEAD" >> "$GITHUB_ENV"
  echo "PR_HEAD_SHA=${PR_HEAD_SHA:-}" >> "$GITHUB_ENV"
  echo "FEATURE_NUM=${FEATURE_NUM:-}" >> "$GITHUB_ENV"
  echo "CHECK_RUN_ID=${CHECK_RUN_ID:-}" >> "$GITHUB_ENV"
  echo "REVIEW_TARGETS_CSV=$REVIEW_TARGETS_CSV" >> "$GITHUB_ENV"
fi
