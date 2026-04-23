#!/usr/bin/env bash
set -euo pipefail
export AUTODUCKS_AGENT="close"
source "$(dirname "${BASH_SOURCE[0]}")/../../core/config/load-config.sh"
source "$AUTODUCKS_ROOT/core/feedback/react-to-comment.sh"

FEATURE="${FEATURE_ISSUE:?FEATURE_ISSUE env var required}"
COMMENTER="${COMMENTER:-unknown}"

react_to_comment "${COMMENT_ID:-}" "eyes"

# Get issue body and extract task numbers
ISSUE_BODY=$(its::get_issue "$FEATURE" | jq -r '.body')
YAML_BLOCK=$(echo "$ISSUE_BODY" | awk '/^```yaml[[:space:]]*$/{flag=1;next}/^```[[:space:]]*$/{flag=0}flag')

TASK_NUMBERS=()
if [[ -n "$YAML_BLOCK" ]]; then
  while IFS= read -r num; do
    [[ -n "$num" ]] && TASK_NUMBERS+=("$num")
  done < <(echo "$YAML_BLOCK" | yq '.waves[].tasks[]' 2>/dev/null | grep -E '^[0-9]+$')
fi

TASKS_CLOSED=0
PRS_CLOSED=0
BRANCHES_DELETED=0

# For each task: close branches, PRs, and issues
for t in "${TASK_NUMBERS[@]:-}"; do
  # Find matching branches
  BRANCHES=$(git::find_branches_matching "feature/${FEATURE}-issue-${t}-")

  while IFS= read -r branch; do
    [[ -z "$branch" ]] && continue

    # Find and close open PR on this branch
    PR_NUM=$(gh pr list --repo "$REPO" --head "$branch" --state open --json number --jq '.[0].number // empty' 2>/dev/null || true)
    if [[ -n "$PR_NUM" ]]; then
      git::close_pr "$PR_NUM" "Closed by \`/agents close\` on feature #$FEATURE" 2>/dev/null || true
      ((PRS_CLOSED++)) || true
    fi

    # Delete branch
    git::delete_branch "$branch"
    ((BRANCHES_DELETED++)) || true
  done <<< "$BRANCHES"

  # Close task issue
  its::close_issue "$t" "Closed via \`/agents close\` on feature #$FEATURE" 2>/dev/null || true
  ((TASKS_CLOSED++)) || true
done

# Handle feature branch
ISSUE_TITLE=$(its::get_issue "$FEATURE" | jq -r '.title')
SLUG=$(git::generate_slug "$FEATURE" "$ISSUE_TITLE")
FEATURE_BRANCH="feature/$SLUG"

if git::branch_exists "$FEATURE_BRANCH" 2>/dev/null; then
  # Close feature PR if exists
  FEATURE_PR=$(gh pr list --repo "$REPO" --head "$FEATURE_BRANCH" --state open --json number --jq '.[0].number // empty' 2>/dev/null || true)
  if [[ -n "$FEATURE_PR" ]]; then
    git::close_pr "$FEATURE_PR" "Closed by \`/agents close\` on feature #$FEATURE" 2>/dev/null || true
    ((PRS_CLOSED++)) || true
  fi

  git::delete_branch "$FEATURE_BRANCH"
  ((BRANCHES_DELETED++)) || true
fi

# Close the feature issue
its::close_issue "$FEATURE" "Feature closed by @$COMMENTER via \`/agents close\`.

**Cleanup summary:**
- Tasks closed: $TASKS_CLOSED
- PRs closed: $PRS_CLOSED
- Branches deleted: $BRANCHES_DELETED"

react_to_comment "${COMMENT_ID:-}" "+1"
