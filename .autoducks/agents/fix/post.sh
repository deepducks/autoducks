#!/usr/bin/env bash
set -euo pipefail
export AUTODUCKS_AGENT="fix"
source "$(dirname "${BASH_SOURCE[0]}")/../../core/config/load-config.sh"
source "$AUTODUCKS_ROOT/core/feedback/react-to-comment.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-failure.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-skip.sh"
source "$AUTODUCKS_ROOT/core/feedback/status-comment.sh"
source "$AUTODUCKS_ROOT/core/robustness/assert-changes.sh"
source "$AUTODUCKS_ROOT/core/orchestration/trigger-loop-closure.sh"
source "$AUTODUCKS_ROOT/core/orchestration/branch-prefix.sh"
source "$AUTODUCKS_ROOT/core/feedback/progress-labels.sh"
source "$AUTODUCKS_ROOT/core/feedback/handle-cancellation.sh"

# Reconstruct state from git (pre.sh exports don't persist across GHA steps).
# `AUTODUCKS_RESOLVED_*` is pre.sh's handoff for the comment-triggered path,
# where the workflow injects no BASE_BRANCH and the fallbacks below would name
# the default branch — which is how the mirrored child branch used to resolve to
# the child's trunk (#182). A step-level `env:` entry outranks $GITHUB_ENV for
# the same name, hence the distinct one.
TASK_BRANCH=$(git rev-parse --abbrev-ref HEAD)
PR_BASE_BRANCH="${AUTODUCKS_RESOLVED_PR_BASE_BRANCH:-${BASE_BRANCH:-$AUTODUCKS_INTEGRATION_BRANCH}}"
BASE_BRANCH="${AUTODUCKS_RESOLVED_BASE_BRANCH:-${BASE_BRANCH:-$AUTODUCKS_BASE_BRANCH}}"
# Metarepo child branches mirror the pipeline feature branch.
CHILD_BRANCH="$PR_BASE_BRANCH"
FEATURE_NUM=""
if [[ "$TASK_BRANCH" =~ ^(feature|fix)/([0-9]+)-issue- ]]; then
  FEATURE_NUM="${BASH_REMATCH[2]}"
fi

trap '_rc=$?; notify_failure "$ISSUE_NUM" "$RUN_ID" "${FEATURE_NUM:-}" 2>/dev/null || true; \
      status_comment::fail "$ISSUE_NUM" 2>/dev/null || true; \
      react_to_comment "${COMMENT_ID:-}" "confused" 2>/dev/null || true; \
      progress_labels::abort "$ISSUE_NUM" "Work:coding" 2>/dev/null || true; \
      exit $_rc' ERR

# pre.sh's own ERR trap already notified on failure — post.sh still runs
# (its step condition is `if: always()`), so bail out quietly to avoid a
# duplicate failure comment.
if [[ -f "$AUTODUCKS_PRE_FAILED_MARKER" ]]; then
  exit 0
fi

cancellation::handle "$ISSUE_NUM" "Work:coding"

if [[ "${LLM_SKIPPED:-}" == "true" ]]; then
  notify_skip "$ISSUE_NUM"
  progress_labels::abort "$ISSUE_NUM" "Work:coding"
  # Do NOT react confused; do NOT call notify_failure.
  exit 0
fi

# Agent hit its turn limit — preserve the partial branch instead of running
# the normal assert/PR/merge flow, which assumes a finished implementation.
if [[ "${LLM_ERROR_SUBTYPE:-}" == "error_max_turns" ]]; then
  export AUTODUCKS_FAIL_CATEGORY="max_turns"
  export AUTODUCKS_FAIL_PHASE="llm"

  if metarepo::enabled; then
    metarepo::commit_task "$ISSUE_NUM" "$CHILD_BRANCH" "WIP: partial work before max_turns (issue #${ISSUE_NUM})" || true
  else
    git add -A
    git commit -m "WIP: partial work before max_turns (issue #${ISSUE_NUM})" || true
  fi
  git::push_branch "$TASK_BRANCH" || true
  export AUTODUCKS_FAIL_BRANCH="$TASK_BRANCH"

  if [[ ! -s /tmp/work-summary.md ]]; then
    echo "_No summary was produced before the turn limit was reached._" > /tmp/work-summary.md
  fi

  notify_failure "$ISSUE_NUM" "$RUN_ID" "${FEATURE_NUM:-}" 2>/dev/null || true
  status_comment::fail "$ISSUE_NUM" 2>/dev/null || true
  react_to_comment "${COMMENT_ID:-}" "confused" 2>/dev/null || true
  progress_labels::abort "$ISSUE_NUM" "Work:coding" 2>/dev/null || true
  exit 1
fi

# Check for changes (allow existing commits on reused branch)
assert_changes "$PR_BASE_BRANCH" || true

# Commit and push (only if there are staged changes). In metarepo mode, push
# child submodules first (children before parent) via metarepo::commit_task.
if metarepo::enabled; then
  metarepo::commit_task "$ISSUE_NUM" "$CHILD_BRANCH" "Fix implementation for issue #${ISSUE_NUM}"
elif ! git diff --cached --quiet 2>/dev/null; then
  git commit -m "Fix implementation for issue #${ISSUE_NUM}"
fi
git::push_branch "$TASK_BRANCH"

# Reuse existing PR or create a new one
EXISTING_PR=$(gh pr list --repo "$REPO" --head "$TASK_BRANCH" --base "$PR_BASE_BRANCH" --json number --jq '.[0].number // empty' 2>/dev/null || true)

if [[ -z "$EXISTING_PR" ]]; then
  ISSUE_TITLE=$(its::get_issue "$ISSUE_NUM" | jq -r '.title')
  PR_NUM=$(git::create_pr "$TASK_BRANCH" "$PR_BASE_BRANCH" "Fix: $ISSUE_TITLE" "fixes #${ISSUE_NUM}")
else
  PR_NUM="$EXISTING_PR"
fi

if [[ -n "${FEATURE_NUM:-}" && "$FEATURE_NUM" != "0" ]]; then
  merge_rc=0
  git::merge_pr "$PR_NUM" || merge_rc=$?
  if [[ "$merge_rc" -ne 0 ]]; then
    if [[ "$merge_rc" -eq 2 ]]; then
      notify_failure "$ISSUE_NUM" "$RUN_ID" "$FEATURE_NUM"
    else
      notify_conflict "$ISSUE_NUM" "$RUN_ID" "$TASK_BRANCH" "$PR_NUM" "$FEATURE_NUM"
    fi
    status_comment::fail "$ISSUE_NUM"
    react_to_comment "$COMMENT_ID" "confused"
    progress_labels::abort "$ISSUE_NUM" "Work:coding"
    exit 1
  fi
  trigger_loop_closure "$FEATURE_NUM"
fi

react_to_comment "$COMMENT_ID" "+1"

# Done-assignee (D15): the command author owns the next action.
its::assign_issue "$ISSUE_NUM" "${COMMENTER:-}" 2>/dev/null || true

if [[ -n "${FEATURE_NUM:-}" && "$FEATURE_NUM" != "0" ]]; then
  # Fix PR auto-merged into the feature/bug branch, orchestrator resumed
  FIX_MSG="**Fix applied and merged.**

PR #$PR_NUM was merged into \`$BASE_BRANCH\` and the Maestro has been
re-triggered to resume the pipeline.

**Next:** nothing — the Maestro continues from here."
else
  # Fix PR awaits human review
  FIX_MSG="**Fix applied.**

PR #$PR_NUM is open and waiting for your review.

**Next:** review and merge PR #$PR_NUM, or comment \`$(autoducks_command_for fix)\` again if the
problem persists."
fi

status_comment::finish "$ISSUE_NUM" "$FIX_MSG

_Ran with \`${MODEL:-unknown}\` at effort \`${EFFORT:-unknown}\`._"
