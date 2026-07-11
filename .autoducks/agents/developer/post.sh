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
source "$AUTODUCKS_ROOT/core/orchestration/trigger-loop-closure.sh"
source "$AUTODUCKS_ROOT/core/orchestration/branch-prefix.sh"
source "$AUTODUCKS_ROOT/core/feedback/progress-labels.sh"
source "$AUTODUCKS_ROOT/core/feedback/handle-cancellation.sh"

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

# Commit unconditionally so `git::commits_ahead` (below) reflects any diff
# the agent produced — the diff is ground truth, checked before deciding
# whether this run is a normal PR, a legitimate no-op, or a genuine failure.
git add -A
git commit -m "Implement issue #${ISSUE_NUM}" || true

NO_OP=false
ahead=$(git::commits_ahead "$PR_BASE_BRANCH")
if [[ "$ahead" -gt 0 ]]; then
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
        2>/dev/null || echo "::warning::Could not close task #$ISSUE_NUM"
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
    2>/dev/null || echo "::warning::Could not close task #$ISSUE_NUM"

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

status_comment::finish "$ISSUE_NUM" "$EXEC_MSG

_Ran with \`${MODEL:-unknown}\` at effort \`${EFFORT:-unknown}\`._"
