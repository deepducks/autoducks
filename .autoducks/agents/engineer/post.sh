#!/usr/bin/env bash
set -euo pipefail
export AUTODUCKS_AGENT="engineer"
source "$(dirname "${BASH_SOURCE[0]}")/../../core/config/load-config.sh"
source "$AUTODUCKS_ROOT/core/feedback/react-to-comment.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-failure.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-skip.sh"
source "$AUTODUCKS_ROOT/core/feedback/status-comment.sh"
source "$AUTODUCKS_ROOT/core/robustness/ask-questions.sh"
source "$AUTODUCKS_ROOT/core/orchestration/reconcile-tasks.sh"
source "$AUTODUCKS_ROOT/core/orchestration/tactical-zone.sh"
source "$AUTODUCKS_ROOT/core/orchestration/dispatch-chain.sh"
source "$AUTODUCKS_ROOT/core/feedback/progress-labels.sh"
source "$AUTODUCKS_ROOT/core/feedback/handle-cancellation.sh"

# Catch-all safety net for anything that fails before an explicit handler
# runs (the explicit sites below set richer categories and are preferred;
# this is only the backstop).
trap '_rc=$?; notify_failure "$ISSUE_NUM" "$RUN_ID" "" 2>/dev/null || true; \
      status_comment::fail "$ISSUE_NUM" 2>/dev/null || true; \
      react_to_comment "${COMMENT_ID:-}" "confused" 2>/dev/null || true; \
      progress_labels::abort "$ISSUE_NUM" "Tactics:crafting" 2>/dev/null || true; \
      exit $_rc' ERR

# Cross-step guards: pre.sh already failed (and posted its own categorized
# comment via the trap mirrored there) or delegated to a prerequisite agent.
# Skip post-processing entirely in both cases.
if [[ -f "$AUTODUCKS_PRE_FAILED_MARKER" || -f "$AUTODUCKS_DOR_DELEGATED_MARKER" ]]; then
  exit 0
fi

cancellation::handle "$ISSUE_NUM" "Tactics:crafting"

if [[ "${LLM_SKIPPED:-}" == "true" ]]; then
  notify_skip "$ISSUE_NUM"
  progress_labels::abort "$ISSUE_NUM" "Tactics:crafting"
  # Do NOT react confused; do NOT call notify_failure.
  exit 0
fi

# Questions mode: the agent wrote questions instead of a plan.
if [[ -f /tmp/questions.md ]]; then
  ask_questions "$ISSUE_NUM" /tmp/questions.md
  react_to_comment "$COMMENT_ID" "+1"
  progress_labels::abort "$ISSUE_NUM" "Tactics:crafting"
  status_comment::finish "$ISSUE_NUM" "**Blocked on questions.** The Engineer needs answers before it can plan — see the questions comment below, answer them, then re-run \`$(autoducks_command_for engineer)\`."
  # A blocked plan never continues the #auto: chain.
  exit 0
fi

# Agent hit its turn limit before producing its output — report the
# max_turns category (with a `turns=<n>` retry hint) rather than
# mislabeling a turn-limit cutoff as scope-missing.
if [[ "${LLM_ERROR_SUBTYPE:-}" == "error_max_turns" ]]; then
  export AUTODUCKS_FAIL_CATEGORY="max_turns" AUTODUCKS_FAIL_PHASE="llm"
  notify_failure "$ISSUE_NUM" "$RUN_ID"
  status_comment::fail "$ISSUE_NUM"
  react_to_comment "$COMMENT_ID" "confused"
  progress_labels::abort "$ISSUE_NUM" "Tactics:crafting"
  exit 1
fi

# Validate tactical zone was produced
if [[ ! -f /tmp/tactical-body.md ]]; then
  export AUTODUCKS_FAIL_CATEGORY="scope-missing"
  notify_failure "$ISSUE_NUM" "$RUN_ID"
  status_comment::fail "$ISSUE_NUM"
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
  status_comment::fail "$ISSUE_NUM"
  react_to_comment "$COMMENT_ID" "confused"
  progress_labels::abort "$ISSUE_NUM" "Tactics:crafting"
  exit 1
fi

# Safety guard against silent design-zone loss: never overwrite the issue body
# when the design zone came out empty while the source body was non-empty. That
# can only happen if zone classification zeroed the design zone (the historical
# Case C bug); abort loudly instead of wiping the human-authored spec.
if [[ ! -s /tmp/design-zone.md && -s /tmp/issue-body-raw.md ]]; then
  its::comment_issue "$ISSUE_NUM" "❌ Aborting \`$(autoducks_command_for engineer)\`: the design zone resolved to empty while the issue body is non-empty. Publishing would wipe the human-authored design, so no changes were made. Check the \`<!-- autoducks:tactical:begin -->\` / \`<!-- autoducks:tactical:end -->\` markers and re-run."
  status_comment::fail "$ISSUE_NUM"
  react_to_comment "$COMMENT_ID" "confused"
  progress_labels::abort "$ISSUE_NUM" "Tactics:crafting"
  exit 1
fi

TASK_COUNT=$(wc -l < /tmp/tasks.jsonl | tr -d ' ')

if [[ "$TASK_COUNT" -eq 1 ]]; then
  # --- SINGLE-TASK FAST PATH ---
  # No child issues, no waves YAML, no Progress checklist — and no special
  # label (D12): the Maestro detects the single-task case structurally, by
  # the absence of a waves plan in the tactical zone.
  TASK_LINE=$(head -1 /tmp/tasks.jsonl)
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

  TASK_NUMBERS=""
else
  # --- MULTI-TASK PATH ---
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
fi

# Legacy-label cleanup (pre-rename installs): Tactics:single and Ready are no
# longer part of the taxonomy (D6/D12).
its::remove_label "$ISSUE_NUM" "Tactics:single" 2>/dev/null || true
its::remove_label "$ISSUE_NUM" "Ready" 2>/dev/null || true

# Completion label — D6: `Tactics:done` is both the record and the routing
# signal for the Maestro.
progress_labels::finish "$ISSUE_NUM" "Tactics:crafting" "Tactics:done"

# Done-assignee (D15): the command author owns the next action.
its::assign_issue "$ISSUE_NUM" "${COMMENTER:-}" 2>/dev/null || true

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
    LINK_SUMMARY=$"\n> Sub-issue linking: $LINKED/$TOTAL tasks linked ($ERR errors, $FORBID forbidden, $UNAVAIL unavailable). Retry \`$(autoducks_command_for engineer)\` to reconcile."
  fi
fi

if [[ "$TASK_COUNT" -eq 1 ]]; then
  status_comment::finish "$ISSUE_NUM" "**Tactical plan complete** (single task — no child issues created; the task lives in the tactical zone of this issue).

**Next:** run \`$(autoducks_command_for execute)\` to implement it.

_Ran with \`${MODEL:-unknown}\` at effort \`${EFFORT:-unknown}\`._"
else
  status_comment::finish "$ISSUE_NUM" "**Tactical plan complete.**

Tasks created: $TASK_NUMBERS. The plan, wave order, and \`## Progress\`
checklist now live in the tactical zone of the issue body.
${LINK_SUMMARY}
**Next:** run \`$(autoducks_command_for execute)\` to start the Maestro, which
dispatches tasks in dependency order.

_Ran with \`${MODEL:-unknown}\` at effort \`${EFFORT:-unknown}\`._"
fi

# ── #auto: chain ─────────────────────────────────────────────────────
# If the run was routed here from an `execute` verb (the user asked for
# execution, but planning had to happen first), continue to execution
# implicitly. Explicit `#auto:` chains are honored either way.
EFFECTIVE_CHAIN="${AUTO_CHAIN:-}"
if [[ "${COMMAND:-}" == "execute" ]]; then
  case "+${EFFECTIVE_CHAIN}+" in
    *"+execute+"*) : ;;
    *) EFFECTIVE_CHAIN="execute${EFFECTIVE_CHAIN:++$EFFECTIVE_CHAIN}" ;;
  esac
fi
chain::dispatch_next "$EFFECTIVE_CHAIN" "$ISSUE_NUM"
