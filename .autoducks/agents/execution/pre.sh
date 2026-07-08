#!/usr/bin/env bash
set -euo pipefail
export AUTODUCKS_AGENT="execution"

# Clear any stale marker from a previous run on this runner before we can
# leave a fresh one behind (see trap below / post.sh's guard).
rm -f /tmp/autoducks-pre-failed

source "$(dirname "${BASH_SOURCE[0]}")/../../core/config/load-config.sh"
source "$AUTODUCKS_ROOT/core/feedback/react-to-comment.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-failure.sh"
source "$AUTODUCKS_ROOT/core/feedback/progress-labels.sh"
source "$AUTODUCKS_ROOT/core/robustness/wait-for-branch.sh"

# Determine base branch and issue number
# These come from the runtime as env vars: ISSUE_NUM, BASE_BRANCH
# PR target — where the resulting PR will merge into (orphan tasks → integration branch)
PR_BASE_BRANCH="${BASE_BRANCH:-$AUTODUCKS_INTEGRATION_BRANCH}"
# Cut-point — where the task branch is branched from. An explicitly-passed
# BASE_BRANCH (wave dispatch) names a feature branch and IS the cut-point;
# absent (orphan task) we cut from the clean upstream base, not integration.
BASE_BRANCH="${BASE_BRANCH:-$AUTODUCKS_BASE_BRANCH}"

# If base branch is a feature branch, extract feature number
FEATURE_NUM=""
if [[ "$BASE_BRANCH" =~ ^feature/([0-9]+) ]]; then
  FEATURE_NUM="${BASH_REMATCH[1]}"
fi

# Catch-all: any uncaught non-zero exit below here posts a categorized
# failure comment on the task issue (and the parent feature, if any),
# reacts confused, aborts the progress label, and leaves a marker so
# post.sh doesn't post a duplicate comment for the same run.
trap '_rc=$?; notify_failure "$ISSUE_NUM" "$RUN_ID" "${FEATURE_NUM:-}" 2>/dev/null || true; \
      react_to_comment "${COMMENT_ID:-}" "confused" 2>/dev/null || true; \
      progress_labels::abort "$ISSUE_NUM" "Work:progress" 2>/dev/null || true; \
      touch /tmp/autoducks-pre-failed; \
      exit $_rc' ERR

react_to_comment "${COMMENT_ID:-}" "eyes"

# Idempotency guard: bail if this task already has a PR (open OR merged) on the
# feature branch. Closes the window between orchestrator dispatch and PR creation
# where two runs may both pass prevent_duplicate_dispatch's open-PR check. The
# execute workflow's per-task `concurrency` group serializes duplicate dispatches,
# so a duplicate runs only after the first has finished — by which point the
# first's PR is already merged (and therefore no longer open); checking merged
# PRs too catches that case.
if [[ -n "$FEATURE_NUM" ]]; then
  EXISTING_PR=$(jq -s 'add' \
      <(git::list_open_prs "$BASE_BRANCH") \
      <(git::list_merged_prs "$BASE_BRANCH") \
    | jq -r --arg t "$ISSUE_NUM" \
        '[.[] | select(.body | test("(?i)(fixes|closes|resolves)\\s+#" + $t + "\\b"))] | .[0].number // empty')
  if [[ -n "$EXISTING_PR" ]]; then
    echo "::notice::Task #$ISSUE_NUM already has PR #$EXISTING_PR (open or merged) — skipping duplicate execution."
    react_to_comment "${COMMENT_ID:-}" "+1" 2>/dev/null || true
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
      echo "duplicate_skip=true" >> "$GITHUB_OUTPUT"
    fi
    exit 0
  fi
fi

progress_labels::ensure
progress_labels::start "$ISSUE_NUM" "Work:progress" "Work:done"

# Wait for base branch to be visible
if [[ "$BASE_BRANCH" != "$AUTODUCKS_BASE_BRANCH" ]]; then
  wait_for_branch "$BASE_BRANCH"
fi

# Generate task branch name
SLUG=$(git::generate_slug "$ISSUE_NUM" "$(its::get_issue "$ISSUE_NUM" | jq -r '.title')")
TASK_BRANCH="feature/${FEATURE_NUM:-0}-issue-${ISSUE_NUM}-$(date +%s)"

# Configure git and create task branch from base
git::configure_identity
git fetch origin "$BASE_BRANCH" 2>/dev/null || true
git checkout "$BASE_BRANCH" 2>/dev/null || true
git checkout -b "$TASK_BRANCH"

# Prepare task spec for the LLM
its::get_issue "$ISSUE_NUM" | jq -r '"# " + .title + "\n\n" + .body' > /tmp/task-spec.md

# Export for post.sh
export TASK_BRANCH BASE_BRANCH PR_BASE_BRANCH FEATURE_NUM
