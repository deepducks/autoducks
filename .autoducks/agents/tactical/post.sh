#!/usr/bin/env bash
set -euo pipefail
export AUTODUCKS_AGENT="tactical"
source "$(dirname "${BASH_SOURCE[0]}")/../../core/config/load-config.sh"
source "$AUTODUCKS_ROOT/core/feedback/react-to-comment.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-failure.sh"
source "$AUTODUCKS_ROOT/core/robustness/ask-questions.sh"
source "$AUTODUCKS_ROOT/core/orchestration/reconcile-tasks.sh"

# Questions mode: if the agent wrote questions instead of a plan
if [[ -f /tmp/questions.md ]]; then
  ask_questions "$ISSUE_NUM" /tmp/questions.md
  react_to_comment "$COMMENT_ID" "+1"
  exit 0
fi

# Validate plan was produced
if [[ ! -f /tmp/plan-body.md ]]; then
  notify_failure "$ISSUE_NUM" "$RUN_ID"
  react_to_comment "$COMMENT_ID" "confused"
  exit 1
fi

# Parse the plan
PARSE_ERROR_FILE=/tmp/parse-error.md
if ! python3 "$AUTODUCKS_ROOT/core/robustness/parse-plan.py" /tmp/plan-body.md /tmp/tasks.jsonl; then
  # Parse failed — post error and exit (runtime may retry)
  if [[ -f "$PARSE_ERROR_FILE" ]]; then
    its::comment_issue "$ISSUE_NUM" "$(cat "$PARSE_ERROR_FILE")"
  fi
  react_to_comment "$COMMENT_ID" "confused"
  exit 1
fi

# Reconcile tasks (create/update/close)
RECONCILE_OUTPUT=$(reconcile_tasks "$ISSUE_NUM" /tmp/tasks.jsonl "${OLD_NUMBERS:-}")

# Extract task numbers and placeholder mappings
TASK_NUMBERS=$(echo "$RECONCILE_OUTPUT" | grep '^TASK_NUMBERS=' | sed 's/^TASK_NUMBERS=//')

# Replace placeholders in plan body
PLAN_BODY=$(cat /tmp/plan-body.md)
while IFS='|' read -r _ placeholder real_num; do
  PLAN_BODY=$(echo "$PLAN_BODY" | perl -pe "s/\\b\\Q${placeholder}\\E\\b/${real_num}/g")
done < <(echo "$RECONCILE_OUTPUT" | grep '^PLACEHOLDER|')

# Strip ## Tasks section from the plan body (tasks are now separate issues)
FEATURE_BODY=$(echo "$PLAN_BODY" | awk '
  /^## Tasks/ { skip=1; next }
  /^## / { if(skip) skip=0 }
  !skip { print }
')

# Write updated feature body
echo "$FEATURE_BODY" > /tmp/feature-body.md
its::update_issue_body "$ISSUE_NUM" /tmp/feature-body.md

if [[ "${IS_REVISION:-false}" != "true" ]]; then
  # First pass: set up labels, type, branch, PR

  # Ensure priority labels exist
  for p in P0 P1 P2 P3; do
    gh label create "priority:$p" --repo "$REPO" 2>/dev/null || true
  done

  # Add Ready label
  its::add_label "$ISSUE_NUM" "Ready"

  # Set issue type to Feature (if not already)
  its::set_issue_type "$ISSUE_NUM" "Feature" 2>/dev/null || true

  # Create feature branch and PR
  ISSUE_TITLE=$(its::get_issue "$ISSUE_NUM" | jq -r '.title')
  SLUG=$(git::generate_slug "$ISSUE_NUM" "$ISSUE_TITLE")
  FEATURE_BRANCH="feature/$SLUG"

  git::create_branch "$AUTODUCKS_BASE_BRANCH" "$FEATURE_BRANCH"

  PR_TITLE="Feature #$ISSUE_NUM: $ISSUE_TITLE"
  PR_BODY="Closes #$ISSUE_NUM"
  git::create_pr "$FEATURE_BRANCH" "$AUTODUCKS_BASE_BRANCH" "$PR_TITLE" "$PR_BODY" || true

  # Assign commenter
  gh issue edit "$ISSUE_NUM" --repo "$REPO" --add-assignee "$COMMENTER" 2>/dev/null || true
fi

react_to_comment "$COMMENT_ID" "+1"

# Notify
its::comment_issue "$ISSUE_NUM" "✅ Tactical plan complete. Tasks created: $TASK_NUMBERS

Use \`/agents execute\` to start implementation, or assign the feature PR to the agents."
