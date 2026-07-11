#!/usr/bin/env bash
set -euo pipefail
export AUTODUCKS_AGENT="developer"

source "$(dirname "${BASH_SOURCE[0]}")/../../core/config/load-config.sh"

# pre.sh's ERR trap already notified on this run's failure, or the DoR guard
# delegated to another agent — bail out quietly so post.sh doesn't post a
# duplicate comment. (_AUTODUCKS_NOTIFIED doesn't carry across GHA steps, so
# these file markers are required instead.)
if [[ -f "$AUTODUCKS_PRE_FAILED_MARKER" || -f "$AUTODUCKS_DOR_DELEGATED_MARKER" ]]; then
  exit 0
fi

source "$AUTODUCKS_ROOT/core/feedback/react-to-comment.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-failure.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-skip.sh"
source "$AUTODUCKS_ROOT/core/feedback/status-comment.sh"
source "$AUTODUCKS_ROOT/core/robustness/assert-changes.sh"
source "$AUTODUCKS_ROOT/core/robustness/verify-loop.sh"
source "$AUTODUCKS_ROOT/core/orchestration/trigger-loop-closure.sh"
source "$AUTODUCKS_ROOT/core/orchestration/branch-prefix.sh"
source "$AUTODUCKS_ROOT/core/feedback/progress-labels.sh"
source "$AUTODUCKS_ROOT/core/feedback/handle-cancellation.sh"

# ── Marker-anchored check-feedback comment (T4) ──────────────────────
# Mirrors orchestrator_comment::upsert's marker-scan pattern (find-or-create
# by scanning its::list_comments for the hidden marker), but also supports
# deletion — this comment must never linger past the retry it describes.
# Kept here (not in verify-loop.sh) since it performs ITS writes, while
# verify-loop.sh stays read-only w.r.t. ITS/git.
# One id file per issue (mirrors status_comment's _id_file), so /tmp never
# confuses two different issues' feedback comments.
_check_feedback_comment_id_file() {
  echo "/tmp/autoducks-check-feedback-comment-id.${1}"
}

_verify_loop::find_feedback_comment_id() {
  local issue_id="$1"
  local comments
  comments=$(its::list_comments "$issue_id" 2>/dev/null) || return 0
  echo "$comments" | jq -r --arg marker "$AUTODUCKS_CHECK_FEEDBACK_MARKER" \
    '[.[] | select((.author == "github-actions[bot]" or .author == "github-actions")
                   and ((.body // "") | contains($marker)))]
     | sort_by(.updated_at // .created_at // "") | last | .id // empty' \
    2>/dev/null
}

# verify_loop::upsert_feedback_comment ISSUE_NUM BODY
# Edits the existing feedback comment in place, or posts a fresh one.
verify_loop::upsert_feedback_comment() {
  local issue_id="$1" body="$2"
  local f; f=$(_check_feedback_comment_id_file "$issue_id")
  local cid=""
  [[ -s "$f" ]] && cid=$(cat "$f" 2>/dev/null || true)
  [[ -z "$cid" ]] && cid=$(_verify_loop::find_feedback_comment_id "$issue_id")

  if [[ -n "$cid" && "$cid" != "null" ]]; then
    echo "$cid" > "$f"
    its::update_comment "$cid" "$body" 2>/dev/null || true
    return 0
  fi

  local out="" new_id=""
  out=$(its::comment_issue "$issue_id" "$body" 2>/dev/null) || return 0
  new_id=$(echo "$out" | grep -oE 'issuecomment-[0-9]+' | grep -oE '[0-9]+' | head -1 || true)
  [[ -n "$new_id" ]] && echo "$new_id" > "$f"
  return 0
}

# verify_loop::clear_feedback_comment ISSUE_NUM
# Deletes the feedback comment (success or give-up path) so it never lingers.
verify_loop::clear_feedback_comment() {
  local issue_id="$1"
  local f; f=$(_check_feedback_comment_id_file "$issue_id")
  local cid=""
  [[ -s "$f" ]] && cid=$(cat "$f" 2>/dev/null || true)
  [[ -z "$cid" ]] && cid=$(_verify_loop::find_feedback_comment_id "$issue_id")
  [[ -n "$cid" && "$cid" != "null" ]] && its::delete_comment "$cid" 2>/dev/null || true
  rm -f "$f"
}

# Reconstruct state from git (pre.sh exports don't persist across GHA steps)
TASK_BRANCH=$(git rev-parse --abbrev-ref HEAD)
PR_BASE_BRANCH="${BASE_BRANCH:-$AUTODUCKS_INTEGRATION_BRANCH}"
BASE_BRANCH="${BASE_BRANCH:-$AUTODUCKS_BASE_BRANCH}"
FEATURE_NUM=$(pipeline_branch_number "$BASE_BRANCH")

# Catch-all: any uncaught non-zero exit below here posts a categorized
# failure comment on the task issue (and the parent feature, if any),
# reacts confused, and aborts the progress label — never a silent red X.
trap '_rc=$?; notify_failure "$ISSUE_NUM" "$RUN_ID" "${FEATURE_NUM:-}" 2>/dev/null || true; \
      status_comment::fail "$ISSUE_NUM" 2>/dev/null || true; \
      react_to_comment "${COMMENT_ID:-}" "confused" 2>/dev/null || true; \
      progress_labels::abort "$ISSUE_NUM" "Work:coding" 2>/dev/null || true; \
      exit $_rc' ERR

cancellation::handle "$ISSUE_NUM" "Work:coding"

if [[ "${LLM_SKIPPED:-}" == "true" ]]; then
  notify_skip "$ISSUE_NUM"
  progress_labels::abort "$ISSUE_NUM" "Work:coding"
  # Do NOT react confused; do NOT call notify_failure.
  exit 0
fi

if [[ "${LLM_ERROR_SUBTYPE:-}" == "error_max_turns" ]]; then
  export AUTODUCKS_FAIL_CATEGORY="max_turns" AUTODUCKS_FAIL_PHASE="llm"
  git add -A
  git commit -m "WIP: partial work from #${ISSUE_NUM} (max_turns cutoff)" || true
  git::push_branch "$TASK_BRANCH" || true          # branch now discoverable by fix/pre.sh
  export AUTODUCKS_FAIL_BRANCH="$TASK_BRANCH"
  # /tmp/work-summary.md may be absent on a max_turns cut — fall back to a
  # machine summary so the comment is never empty:
  [[ -s /tmp/work-summary.md ]] || git diff --stat "origin/$BASE_BRANCH"...HEAD > /tmp/work-summary.md 2>/dev/null || true
  notify_failure "$ISSUE_NUM" "$RUN_ID" "${FEATURE_NUM:-}"   # emits max_turns guidance + branch
  status_comment::fail "$ISSUE_NUM"
  react_to_comment "${COMMENT_ID:-}" "confused"
  progress_labels::abort "$ISSUE_NUM" "Work:coding"
  exit 1
fi

# Check agent made changes
if ! assert_changes; then
  notify_failure "$ISSUE_NUM" "$RUN_ID" "${FEATURE_NUM:+$FEATURE_NUM}"
  status_comment::fail "$ISSUE_NUM"
  react_to_comment "${COMMENT_ID:-}" "confused"
  progress_labels::abort "$ISSUE_NUM" "Work:coding"
  exit 1
fi

# Commit locally
git add -A
git commit -m "Implement issue #${ISSUE_NUM}" || true

# ── Capped verification loop (T2-T4): run configured checks before the PR
# ever opens; a failure re-dispatches this same task for another LLM pass
# instead of shipping broken work, up to AUTODUCKS_CHECKS_MAX_ITERATIONS.
CHECKS_NOTE=""
if verify_loop::enabled; then
  ITERATION="${ITERATION:-1}"
  MAX="$AUTODUCKS_CHECKS_MAX_ITERATIONS"

  # Capture the exit code immediately — set -e / the ERR trap / intermediate
  # commands would otherwise clobber a bare $? by the time the if runs.
  rc=0
  verify_loop::run_checks || rc=$?

  if [[ "$rc" -eq 0 ]]; then
    verify_loop::clear_feedback_comment "$ISSUE_NUM"
    CHECKS_NOTE="Automated checks passed on attempt ${ITERATION}/${MAX}."
    : # fall through to push + PR + auto-merge below
  elif [[ "$rc" -eq 2 ]]; then
    # Setup/infra error — categorize as infra, do NOT consume an iteration.
    export AUTODUCKS_FAIL_CATEGORY="infra" AUTODUCKS_FAIL_PHASE="post"
    notify_failure "$ISSUE_NUM" "$RUN_ID" "${FEATURE_NUM:-}"
    status_comment::fail "$ISSUE_NUM"
    react_to_comment "${COMMENT_ID:-}" "confused"
    progress_labels::abort "$ISSUE_NUM" "Work:coding"
    exit 1
  elif (( ITERATION < MAX )); then
    git::push_branch "$TASK_BRANCH"                      # WIP, resumable
    verify_loop::upsert_feedback_comment "$ISSUE_NUM" "$(verify_loop::feedback_body "$ITERATION" "$MAX")"
    status_comment::note "$ISSUE_NUM" "Check failed — retrying ($((ITERATION+1))/$MAX)…"
    git::dispatch_workflow "autoducks-developer.yml" \
        -f issue_number="$ISSUE_NUM" -f base_branch="$BASE_BRANCH" \
        -f iteration="$((ITERATION+1))" \
        ${COMMENTER:+-f actor="$COMMENTER"} \
        ${MODEL:+-f model="$MODEL"} \
        ${EFFORT:+-f effort="$EFFORT"} \
        ${MAX_TURNS:+-f max_turns="$MAX_TURNS"}
    exit 0                                               # this iteration ends cleanly
  else
    verify_loop::clear_feedback_comment "$ISSUE_NUM"
    git::push_branch "$TASK_BRANCH" || true             # preserve this iteration's commit for /fix
    export AUTODUCKS_FAIL_CATEGORY="check_failed" AUTODUCKS_FAIL_PHASE="post"
    export AUTODUCKS_FAIL_BRANCH="$TASK_BRANCH"          # leave for /fix
    notify_failure "$ISSUE_NUM" "$RUN_ID" "${FEATURE_NUM:-}"
    status_comment::fail "$ISSUE_NUM"
    progress_labels::abort "$ISSUE_NUM" "Work:coding"
    exit 1
  fi
fi

# Push
git::push_branch "$TASK_BRANCH"

# Get issue title for PR
ISSUE_TITLE=$(its::get_issue "$ISSUE_NUM" | jq -r '.title')
PR_TITLE="Task #$ISSUE_NUM: $ISSUE_TITLE"

# Create PR
PR_NUM=$(git::create_pr "$TASK_BRANCH" "$PR_BASE_BRANCH" "$PR_TITLE" "fixes #${ISSUE_NUM}")

# Append implementation summary to PR body, if the agent produced one
if [[ -f /tmp/work-summary.md && -s /tmp/work-summary.md ]]; then
  SUMMARY=$(cat /tmp/work-summary.md)
  PR_BODY="fixes #${ISSUE_NUM}

## Implementation Summary

$SUMMARY"
  git::update_pr_body "$PR_NUM" "$PR_BODY"
fi

if [[ -n "${FEATURE_NUM:-}" && "$FEATURE_NUM" != "0" ]]; then
  # Task with a feature/bug parent — auto-merge with rebase retry
  MERGE_OK=false
  FAILURE_REASON="conflict"
  for attempt in 1 2 3; do
    merge_rc=0
    git::merge_pr "$PR_NUM" || merge_rc=$?
    if [[ "$merge_rc" -eq 0 ]]; then
      MERGE_OK=true
      break
    fi
    if [[ "$merge_rc" -eq 2 ]]; then
      # Merge method not allowed — a config problem, not a stale branch.
      # Rebasing won't help, so stop retrying.
      echo "Merge method not allowed on $REPO — aborting retries (see merge_method config)."
      FAILURE_REASON="config"
      break
    fi
    echo "Merge attempt $attempt failed — rebasing onto $PR_BASE_BRANCH..."
    git fetch origin "$PR_BASE_BRANCH"
    if ! git rebase "origin/$PR_BASE_BRANCH"; then
      echo "Rebase conflict on attempt $attempt — aborting"
      git rebase --abort 2>/dev/null || true
      FAILURE_REASON="conflict"
      break
    fi
    git push --force-with-lease origin "$TASK_BRANCH"
  done

  if [[ "$MERGE_OK" != "true" ]]; then
    if [[ "$FAILURE_REASON" == "conflict" ]]; then
      notify_conflict "$ISSUE_NUM" "$RUN_ID" "$TASK_BRANCH" "$PR_NUM" "$FEATURE_NUM"
    else
      notify_failure "$ISSUE_NUM" "$RUN_ID" "$FEATURE_NUM"
    fi
    status_comment::fail "$ISSUE_NUM"
    react_to_comment "${COMMENT_ID:-}" "confused"
    progress_labels::abort "$ISSUE_NUM" "Work:coding"
    exit 1
  fi

  # Sub-PRs merge into the feature branch, not the default branch, so
  # GitHub's "fixes #N" auto-close does not fire. Close the task explicitly.
  its::close_issue "$ISSUE_NUM" \
    "Auto-closed by the Developer agent after merging sub-PR #$PR_NUM into \`$BASE_BRANCH\`." \
    "completed" \
    2>/dev/null || echo "::warning::Could not close task #$ISSUE_NUM"

  # Trigger orchestrator continuation (non-fatal — the PR merge event is the
  # primary trigger)
  trigger_loop_closure "$FEATURE_NUM" || true
fi

react_to_comment "${COMMENT_ID:-}" "+1"

progress_labels::finish "$ISSUE_NUM" "Work:coding" "Work:done"

# Done-assignee (D15): the command author owns the next action.
its::assign_issue "$ISSUE_NUM" "${COMMENTER:-}" 2>/dev/null || true

if [[ -n "${FEATURE_NUM:-}" && "$FEATURE_NUM" != "0" ]]; then
  EXEC_MSG="**Task implemented and merged.**

PR #$PR_NUM was merged into \`$BASE_BRANCH\` and this task was closed. The
Maestro has been notified and will advance to the next wave automatically.

**Next:** nothing — the Maestro drives the feature to completion from here."
else
  # Manually-dispatched task against the base branch — PR awaits human review
  EXEC_MSG="**Implementation complete.**

PR #$PR_NUM is open against \`$PR_BASE_BRANCH\` and is waiting for your review — it
is **not** auto-merged.

**Next:** review and merge PR #$PR_NUM, or comment \`$(autoducks_command_for fix)\` on this issue
if changes are needed."
fi

FOOTER="_Ran with \`${MODEL:-unknown}\` at effort \`${EFFORT:-unknown}\`._"
[[ -n "$CHECKS_NOTE" ]] && FOOTER="$FOOTER $CHECKS_NOTE"

status_comment::finish "$ISSUE_NUM" "$EXEC_MSG

$FOOTER"
