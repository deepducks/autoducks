#!/usr/bin/env bash
set -euo pipefail
export AUTODUCKS_AGENT="fix"
source "$(dirname "${BASH_SOURCE[0]}")/../../core/config/load-config.sh"
source "$AUTODUCKS_ROOT/core/feedback/react-to-comment.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-failure.sh"
source "$AUTODUCKS_ROOT/core/robustness/assert-changes.sh"
source "$AUTODUCKS_ROOT/core/orchestration/trigger-loop-closure.sh"

# Reconstruct state from git (pre.sh exports don't persist across GHA steps)
TASK_BRANCH=$(git rev-parse --abbrev-ref HEAD)
PR_BASE_BRANCH="${BASE_BRANCH:-$AUTODUCKS_INTEGRATION_BRANCH}"
BASE_BRANCH="${BASE_BRANCH:-$AUTODUCKS_BASE_BRANCH}"
FEATURE_NUM=""
if [[ "$TASK_BRANCH" =~ ^feature/([0-9]+)-issue- ]]; then
  FEATURE_NUM="${BASH_REMATCH[1]}"
fi

# Check for changes (allow existing commits on reused branch)
assert_changes || true

# Commit and push (only if there are staged changes)
if ! git diff --cached --quiet 2>/dev/null; then
  git commit -m "Fix implementation for issue #${ISSUE_NUM}"
fi
git::push_branch "$TASK_BRANCH"

# Check for existing PR
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
    react_to_comment "$COMMENT_ID" "confused"
    exit 1
  fi
  trigger_loop_closure "$FEATURE_NUM"
fi

react_to_comment "$COMMENT_ID" "+1"

if [[ -n "${FEATURE_NUM:-}" && "$FEATURE_NUM" != "0" ]]; then
  # Scenario B: fix PR auto-merged into the feature branch, orchestrator resumed
  FIX_MSG="✅ **Fix applied and merged.**

PR #$PR_NUM was merged into \`$BASE_BRANCH\` and the wave orchestrator has been
re-triggered to resume the feature.

**Next:** nothing — the orchestrator continues from here."
else
  # Scenario A: fix PR awaits human review
  FIX_MSG="✅ **Fix applied.**

PR #$PR_NUM is open and waiting for your review.

**Next:** review and merge PR #$PR_NUM, or comment \`/agents fix\` again if the
problem persists."
fi

its::comment_issue "$ISSUE_NUM" "$FIX_MSG

_Ran with \`${MODEL:-unknown}\` at reasoning \`${REASONING:-unknown}\`._"
