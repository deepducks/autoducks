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

# ── Metarepo recursive commit (children-first) ─────────────────────────
# In metarepo mode the real code lives in child submodules on the mirrored
# feature branch; the parent task branch carries only gitlink bumps. This helper
# enforces the drift guard (changed submodules ⊆ the task's declared modules),
# then commits/pushes each changed child *before* staging the parent gitlinks —
# preserving the HANDOFF push order so a fresh clone always resolves.
# Child branches mirror the pipeline feature branch (PR_BASE_BRANCH). The commit
# logic (drift guard + children-first push) lives in metarepo::commit_task.
CHILD_BRANCH="$PR_BASE_BRANCH"

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
  if metarepo::enabled; then
    # Push partial child work first so the parent gitlink never points at
    # un-pushed child commits (drift guard failure here just skips the push).
    metarepo::commit_task "$ISSUE_NUM" "$CHILD_BRANCH" "WIP: partial work from #${ISSUE_NUM} (max_turns cutoff)" || true
  else
    git add -A
    git commit -m "WIP: partial work from #${ISSUE_NUM} (max_turns cutoff)" || true
  fi
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

# Commit unconditionally so `git::commits_ahead` (below) reflects any diff
# the agent produced — the diff is ground truth, checked before deciding
# whether this run is a normal PR, a legitimate no-op, or a genuine failure.
# In metarepo mode, real code is pushed to child submodules first (children
# before parent) and the parent commit records only the gitlink bumps.
if metarepo::enabled; then
  metarepo::commit_task "$ISSUE_NUM" "$CHILD_BRANCH" "Implement issue #${ISSUE_NUM}"
else
  git add -A
  git commit -m "Implement issue #${ISSUE_NUM}" || true
fi

# Verify-loop footer note (T2-T4); set on a passing check run below. Defined
# at top level so the footer can read it under `set -u` on every code path.
CHECKS_NOTE=""

NO_OP=false
ahead=$(git::commits_ahead "$PR_BASE_BRANCH")
if [[ "$ahead" -gt 0 ]]; then
  # ── Capped verification loop (T2-T4): run configured checks before the PR
  # ever opens; a failure re-dispatches this same task for another LLM pass
  # instead of shipping broken work, up to AUTODUCKS_CHECKS_MAX_ITERATIONS.
  if verify_loop::enabled; then
    ITERATION="${ITERATION:-1}"
    MAX="${MAX_ITERATIONS:-$AUTODUCKS_CHECKS_MAX_ITERATIONS}"

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
      verify_loop::clear_feedback_comment "$ISSUE_NUM"   # no stale note (#989)
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
          ${MAX_TURNS:+-f max_turns="$MAX_TURNS"} \
          ${MAX_ITERATIONS:+-f max_iterations="$MAX_ITERATIONS"}
      exit 0                                               # this iteration ends cleanly
    else
      verify_loop::clear_feedback_comment "$ISSUE_NUM"
      git::push_branch "$TASK_BRANCH" || true             # preserve this iteration for /fix
      export AUTODUCKS_FAIL_CATEGORY="check_failed" AUTODUCKS_FAIL_PHASE="post"
      export AUTODUCKS_FAIL_BRANCH="$TASK_BRANCH"          # leave for /fix
      # Report the cap the loop actually enforced (honours an `iters:` override),
      # not the config default, so the diagnosis matches reality (#989).
      export AUTODUCKS_CHECKS_MAX_ITERATIONS="$MAX"
      notify_failure "$ISSUE_NUM" "$RUN_ID" "${FEATURE_NUM:-}"
      status_comment::fail "$ISSUE_NUM"
      progress_labels::abort "$ISSUE_NUM" "Work:coding"
      exit 1
    fi
  fi

  # Normal path: push, create the PR, merge-retry, close the real sub-task.
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
    # GitHub's "fixes #N" auto-close does not fire. Close the task
    # explicitly — but never the feature issue itself: a feature closes only
    # when a human merges its delivery PR into main (Fix 1).
    if [[ "$ISSUE_NUM" != "$FEATURE_NUM" ]]; then
      its::close_issue "$ISSUE_NUM" \
        "Auto-closed by the Developer agent after merging sub-PR #$PR_NUM into \`$BASE_BRANCH\`." \
        "completed" \
        || echo "::warning::Could not close task #$ISSUE_NUM"
    fi

    # Trigger orchestrator continuation (non-fatal — the PR merge event is the
    # primary trigger)
    trigger_loop_closure "$FEATURE_NUM" || true
  fi
elif [[ "$ISSUE_NUM" != "$FEATURE_NUM" && -s "$AUTODUCKS_NO_CODE_RESULT" ]]; then
  # Legitimate no-op: the agent's deliverable is a recorded finding, not a
  # code diff. No PR, no failure — record the result, close the sub-task,
  # and explicitly wake the Maestro (there is no PR-merge event to do it).
  # A single-task no-op (ISSUE_NUM == FEATURE_NUM) is excluded above and
  # falls through to the assert_changes failure path below instead — a
  # feature issue must never close without a reviewed delivery PR (Fix 1,
  # D16).
  NO_OP=true
  NO_CODE_RESULT=$(cat "$AUTODUCKS_NO_CODE_RESULT")
  its::comment_issue "$ISSUE_NUM" "$NO_CODE_RESULT" \
    2>/dev/null || echo "::warning::Could not comment on task #$ISSUE_NUM"
  its::close_issue "$ISSUE_NUM" \
    "Auto-closed by the Developer agent — no code change was required; see the recorded result above." \
    "completed" \
    || echo "::warning::Could not close task #$ISSUE_NUM"

  if [[ -n "${FEATURE_NUM:-}" && "$FEATURE_NUM" != "0" ]]; then
    git::dispatch_workflow "autoducks-maestro.yml" \
      -f "feature_issue=$FEATURE_NUM" \
      ${COMMENTER:+-f "actor=$COMMENTER"} || true
  fi
else
  # Empty diff and no recorded result — the agent produced nothing.
  if ! assert_changes "$PR_BASE_BRANCH"; then
    notify_failure "$ISSUE_NUM" "$RUN_ID" "${FEATURE_NUM:+$FEATURE_NUM}"
    status_comment::fail "$ISSUE_NUM"
    react_to_comment "${COMMENT_ID:-}" "confused"
    progress_labels::abort "$ISSUE_NUM" "Work:coding"
    exit 1
  fi
fi

react_to_comment "${COMMENT_ID:-}" "+1"

progress_labels::finish "$ISSUE_NUM" "Work:coding" "Work:done"

# Done-assignee (D15): the command author owns the next action.
its::assign_issue "$ISSUE_NUM" "${COMMENTER:-}" 2>/dev/null || true

if [[ "$NO_OP" == "true" ]]; then
  if [[ -n "${FEATURE_NUM:-}" && "$FEATURE_NUM" != "0" ]]; then
    EXEC_MSG="**No code change — result recorded.**

This task's deliverable was a recorded finding rather than a code change. It
has been posted as a comment on this issue and the task was closed. The
Maestro has been notified and will advance to the next wave automatically.

**Next:** nothing — the Maestro drives the feature to completion from here."
  else
    # Manually-dispatched, parent-less no-op — there is no Maestro to notify.
    EXEC_MSG="**No code change — result recorded.**

This task's deliverable was a recorded finding rather than a code change. It
has been posted as a comment on this issue and the task was closed.

**Next:** nothing further is required."
  fi
elif [[ -n "${FEATURE_NUM:-}" && "$FEATURE_NUM" != "0" ]]; then
  if [[ "$ISSUE_NUM" == "$FEATURE_NUM" ]]; then
    # Single-task mode — the Developer ran directly on the feature issue, so
    # this sub-PR merged into the feature branch itself. The feature closes
    # only when a human merges its delivery PR into the integration branch.
    EXEC_MSG="**Implementation complete.**

PR #$PR_NUM was merged into \`$BASE_BRANCH\` (the feature branch). A draft
delivery PR (\`$BASE_BRANCH\` → \`$AUTODUCKS_INTEGRATION_BRANCH\`) now awaits
your review — the feature closes only when you merge it.

**Next:** review and merge the draft delivery PR, or comment \`$(autoducks_command_for fix)\`
on this issue if changes are needed."
  else
    EXEC_MSG="**Task implemented and merged.**

PR #$PR_NUM was merged into \`$BASE_BRANCH\` and this task was closed. The
Maestro has been notified and will advance to the next wave automatically.

**Next:** nothing — the Maestro drives the feature to completion from here."
  fi
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
