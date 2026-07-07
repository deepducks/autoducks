#!/usr/bin/env bash
set -euo pipefail
export AUTODUCKS_AGENT="tactical"
source "$(dirname "${BASH_SOURCE[0]}")/../../core/config/load-config.sh"
source "$AUTODUCKS_ROOT/core/feedback/react-to-comment.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-failure.sh"
source "$AUTODUCKS_ROOT/core/robustness/ask-questions.sh"
source "$AUTODUCKS_ROOT/core/orchestration/reconcile-tasks.sh"
source "$AUTODUCKS_ROOT/core/orchestration/tactical-zone.sh"
source "$AUTODUCKS_ROOT/core/feedback/progress-labels.sh"

# Questions mode: if the agent wrote questions instead of a plan
if [[ -f /tmp/questions.md ]]; then
  ask_questions "$ISSUE_NUM" /tmp/questions.md
  react_to_comment "$COMMENT_ID" "+1"
  progress_labels::abort "$ISSUE_NUM" "Tactics:crafting"
  exit 0
fi

# Validate tactical zone was produced
if [[ ! -f /tmp/tactical-body.md ]]; then
  notify_failure "$ISSUE_NUM" "$RUN_ID"
  react_to_comment "$COMMENT_ID" "confused"
  progress_labels::abort "$ISSUE_NUM" "Tactics:crafting"
  exit 1
fi

# Parse the tactical body
PARSE_ERROR_FILE=/tmp/parse-error.md
if ! python3 "$AUTODUCKS_ROOT/core/robustness/parse-plan.py" /tmp/tactical-body.md /tmp/tasks.jsonl; then
  # Parse failed — post error and exit (runtime may retry)
  if [[ -f "$PARSE_ERROR_FILE" ]]; then
    its::comment_issue "$ISSUE_NUM" "$(cat "$PARSE_ERROR_FILE")"
  fi
  react_to_comment "$COMMENT_ID" "confused"
  progress_labels::abort "$ISSUE_NUM" "Tactics:crafting"
  exit 1
fi

# Safety guard against silent design-zone loss: never overwrite the issue body
# when the design zone came out empty while the source body was non-empty. That
# can only happen if zone classification zeroed the design zone (the historical
# Case C bug); abort loudly instead of wiping the human-authored spec.
if [[ ! -s /tmp/design-zone.md && -s /tmp/issue-body-raw.md ]]; then
  its::comment_issue "$ISSUE_NUM" "❌ Aborting \`/agents devise\`: the design zone resolved to empty while the issue body is non-empty. Publishing would wipe the human-authored design spec, so no changes were made. Check the \`<!-- autoducks:tactical:begin -->\` / \`<!-- autoducks:tactical:end -->\` markers and re-run."
  react_to_comment "$COMMENT_ID" "confused"
  progress_labels::abort "$ISSUE_NUM" "Tactics:crafting"
  exit 1
fi

TASK_COUNT=$(wc -l < /tmp/tasks.jsonl | tr -d ' ')

if [[ "$TASK_COUNT" -eq 1 ]]; then
  # --- SINGLE-TASK FAST PATH ---
  TASK_LINE=$(head -1 /tmp/tasks.jsonl)
  # .body is a complete markdown block from parse-plan.py's build_issue_body:
  #   ## Summary … / ## Tasks … / ## Acceptance Criteria … [/ ## References …]
  # Build the tactical zone from it — NO waves: YAML, NO ## Progress checklist.
  echo "$TASK_LINE" | jq -r '.body' > /tmp/tactical-zone-new.md

  # Assemble via the shared assembler so the tactical sentinels survive
  # (required for a later single→multi re-split).
  assemble_body /tmp/design-zone.md /tmp/tactical-zone-new.md /tmp/feature-body.md
  its::update_issue_body "$ISSUE_NUM" /tmp/feature-body.md

  # Multi→single revision: close the now-dropped child tasks ourselves,
  # since reconcile_tasks (which normally closes dropped tasks) is skipped.
  # OLD_NUMBERS is "" for a single-task source body (no YAML) → no-op.
  for old in ${OLD_NUMBERS:-}; do
    its::close_issue "$old" "Superseded by revised single-task plan on #$ISSUE_NUM" "not_planned" 2>/dev/null || true
  done

  # Lazily create + add Tactics:single (mirror the priority:P* creation style).
  gh label create "Tactics:single" --repo "$REPO" 2>/dev/null || true
  its::add_label "$ISSUE_NUM" "Tactics:single"

  TASK_NUMBERS=""
else
  # --- MULTI-TASK PATH (unchanged) ---
  # Reconcile tasks (create/update/close)
  RECONCILE_OUTPUT=$(reconcile_tasks "$ISSUE_NUM" /tmp/tasks.jsonl "${OLD_NUMBERS:-}")

  # Extract task numbers and placeholder mappings
  TASK_NUMBERS=$(echo "$RECONCILE_OUTPUT" | grep '^TASK_NUMBERS=' | sed 's/^TASK_NUMBERS=//')

  # Replace placeholders in tactical body
  TACTICAL_BODY=$(cat /tmp/tactical-body.md)
  while IFS='|' read -r _ placeholder real_num; do
    TACTICAL_BODY=$(echo "$TACTICAL_BODY" | perl -pe "s/\\b\\Q${placeholder}\\E\\b/${real_num}/g")
  done < <(echo "$RECONCILE_OUTPUT" | grep '^PLACEHOLDER|')

  # Strip ## Tasks block (tasks are now separate issues)
  TACTICAL_STRIPPED=$(echo "$TACTICAL_BODY" | awk '
    /^## Tasks/ { skip=1; next }
    /^## /      { if (skip) skip=0 }
    !skip { print }
  ')
  echo "$TACTICAL_STRIPPED" > /tmp/tactical-zone-new.md

  # Assemble design zone + new tactical zone → feature body
  assemble_body /tmp/design-zone.md /tmp/tactical-zone-new.md /tmp/feature-body.md

  its::update_issue_body "$ISSUE_NUM" /tmp/feature-body.md

  # Clear a stale Tactics:single so a single→multi revision cleans up:
  its::remove_label "$ISSUE_NUM" "Tactics:single" 2>/dev/null || true
fi

# Labels and type (idempotent — safe on both first pass and revision)
its::add_label "$ISSUE_NUM" "Ready"
progress_labels::finish "$ISSUE_NUM" "Tactics:crafting" "Tactics:ready"
its::set_issue_type "$ISSUE_NUM" "Feature" 2>/dev/null || true
its::add_label "$ISSUE_NUM" "Feature"

# Feature branch and PR — create if missing (handles first pass and
# recovery from a prior run that crashed before reaching this point)
ISSUE_TITLE=$(its::get_issue "$ISSUE_NUM" | jq -r '.title')
SLUG=$(git::generate_slug "$ISSUE_NUM" "$ISSUE_TITLE")
FEATURE_BRANCH="feature/$SLUG"

if ! git::branch_exists "$FEATURE_BRANCH"; then
  git::create_branch "$AUTODUCKS_BASE_BRANCH" "$FEATURE_BRANCH"
fi

EXISTING_FEATURE_PR=$(gh pr list --repo "$REPO" --head "$FEATURE_BRANCH" --base "$AUTODUCKS_INTEGRATION_BRANCH" --json number --jq '.[0].number // empty' 2>/dev/null || true)
if [[ -z "$EXISTING_FEATURE_PR" ]]; then
  PR_TITLE="Feature #$ISSUE_NUM: $ISSUE_TITLE"
  PR_BODY="Closes #$ISSUE_NUM"
  git::create_pr "$FEATURE_BRANCH" "$AUTODUCKS_INTEGRATION_BRANCH" "$PR_TITLE" "$PR_BODY" true || true
fi

if [[ "${IS_REVISION:-false}" != "true" ]]; then
  # First pass only: priority labels and assignee
  for p in P0 P1 P2 P3; do
    gh label create "priority:$p" --repo "$REPO" 2>/dev/null || true
  done
  gh issue edit "$ISSUE_NUM" --repo "$REPO" --add-assignee "$COMMENTER" 2>/dev/null || true
fi

react_to_comment "$COMMENT_ID" "+1"

# Summarize sub-issue linking outcome (multi-task path only — the single-task
# fast path never creates child issues, so there is nothing to link)
LINK_SUMMARY=""
if [[ "$TASK_COUNT" -ne 1 && -s /tmp/link-outcomes.tsv ]]; then
  TOTAL=$(wc -l < /tmp/link-outcomes.tsv)
  LINKED=$(grep -cE $'\tlinked$|\talready-linked$' /tmp/link-outcomes.tsv || true)
  UNAVAIL=$(grep -cE $'\tunavailable$' /tmp/link-outcomes.tsv || true)
  FORBID=$(grep -cE $'\tforbidden$' /tmp/link-outcomes.tsv || true)
  ERR=$(grep -cE $'\terror$' /tmp/link-outcomes.tsv || true)

  if (( UNAVAIL == TOTAL )); then
    LINK_SUMMARY=$'\n> Native sub-issue linking is not available for this repository — the `## Progress` checklist above is the primary progress view.'
  elif (( FORBID == TOTAL )); then
    LINK_SUMMARY=$'\n> Native sub-issue linking was refused (token missing `issues:write` scope on this repository).'
  elif (( LINKED == TOTAL )); then
    LINK_SUMMARY=$'\n> All tasks linked as native sub-issues — the parent issue now shows a progress bar in the GitHub UI.'
  else
    LINK_SUMMARY=$"\n> Sub-issue linking: $LINKED/$TOTAL tasks linked ($ERR errors, $FORBID forbidden, $UNAVAIL unavailable). Retry with \`/agents devise\` to reconcile."
  fi
fi

# Notify
if [[ "$TASK_COUNT" -eq 1 ]]; then
  its::comment_issue "$ISSUE_NUM" "✅ Tactical plan complete (single-task fast path — no child issues created).
_Ran with \`${MODEL:-unknown}\` at reasoning \`${REASONING:-unknown}\`._"
else
  its::comment_issue "$ISSUE_NUM" "✅ **Tactical plan complete.**

Tasks created: $TASK_NUMBERS. The plan, wave order, and \`## Progress\`
checklist now live in the tactical zone of the issue body.
${LINK_SUMMARY}
**Next:** run \`/agents execute\` to start the wave orchestrator, which will
dispatch these tasks in dependency order.

_Ran with \`${MODEL:-unknown}\` at reasoning \`${REASONING:-unknown}\`._"
fi
