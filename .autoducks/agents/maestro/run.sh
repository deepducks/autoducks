#!/usr/bin/env bash
set -euo pipefail
export AUTODUCKS_AGENT="maestro"
source "$(dirname "${BASH_SOURCE[0]}")/../../core/config/load-config.sh"
source "$AUTODUCKS_ROOT/core/feedback/react-to-comment.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-failure.sh"
source "$AUTODUCKS_ROOT/core/feedback/status-comment.sh"
source "$AUTODUCKS_ROOT/core/feedback/update-checkboxes.sh"
source "$AUTODUCKS_ROOT/core/orchestration/parse-waves.sh"
source "$AUTODUCKS_ROOT/core/orchestration/prevent-duplicate-dispatch.sh"
source "$AUTODUCKS_ROOT/core/orchestration/create-final-pr.sh"
source "$AUTODUCKS_ROOT/core/orchestration/branch-prefix.sh"
source "$AUTODUCKS_ROOT/core/orchestration/dispatch-chain.sh"
source "$AUTODUCKS_ROOT/core/orchestration/orchestrator-mode.sh"
source "$AUTODUCKS_ROOT/core/feedback/progress-labels.sh"

log() { echo "[maestro] $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# ── Metarepo delivery (children-first, before the parent final PR) ──────
# Advance each affected child (union of the tasks' declared modules): unprotected
# children fast-forward their default branch and drop the feature branch (SHA now
# reachable on main); protected children get a marked, auto-merged PR. Runs
# BEFORE create_final_pr so the parent (which the human merges last) always
# points at child SHAs that will stay reachable after teardown. No-op outside
# metarepo mode.
#
# STDOUT contract (single line): the delivered child_set, comma-joined and
# sorted — callers pass this straight to create_final_pr, which stamps it as
# the `<!-- autoducks:delivered-children: ... -->` marker the poller reads.
deliver_children() {
  metarepo::enabled || return 0
  local feature_branch="$1"; shift
  local -A child_set=()
  local t body m
  for t in "$@"; do
    [[ -z "$t" ]] && continue
    body="$(its::get_issue "$t" | jq -r '.body' 2>/dev/null || true)"
    while IFS= read -r m; do [[ -n "$m" ]] && child_set["$m"]=1; done \
      < <(metarepo::modules_from_body "$body")
  done
  # Deliver each child; collect gitlinks that a squash/rebase rewrote so we can
  # re-pin the parent to the SHA now on the child's default branch.
  local -a repin_pairs=()
  local out pin needs
  for m in "${!child_set[@]}"; do
    log "metarepo delivery: child '$m' → advance from $feature_branch"
    out="$(git::submodule_deliver "$m" "$feature_branch")" || log "WARN: submodule_deliver failed for '$m' (continuing)"
    read -r pin needs <<< "${out:-}"
    if [[ "${needs:-0}" == "1" && -n "${pin:-}" ]]; then
      repin_pairs+=("$m=$pin")
    fi
  done
  # Squash/rebase rewrote some child SHAs → re-pin the parent gitlinks (and delete
  # the retained child branches) before the parent's final PR is created.
  if [[ "${#repin_pairs[@]}" -gt 0 ]]; then
    log "metarepo delivery: re-pinning ${#repin_pairs[@]} gitlink(s) after squash/rebase"
    metarepo::repin_gitlinks "$feature_branch" "${repin_pairs[@]}" || log "WARN: gitlink re-pin failed (continuing)"
  fi
  printf '%s\n' "${!child_set[@]}" | sort | paste -sd, -
}

trap 'progress_labels::abort "$FEATURE" "Work:orchestrating" 2>/dev/null || true; \
     notify_failure "$FEATURE" "$RUN_ID" 2>/dev/null || true; \
     status_comment::fail "$FEATURE" 2>/dev/null || true; \
     exit 1' ERR

react_to_comment "${COMMENT_ID:-}" "eyes"

# --- Phase 1: Determine feature issue ---
FEATURE="${FEATURE_ISSUE:?FEATURE_ISSUE env var required}"

# Bot-owned status comment (D3) — only for human-initiated runs; event-driven
# wave advances already narrate themselves via 🌊/⏳/🎉 comments.
if [[ "${COMMENT_ID:-0}" != "0" ]]; then
  status_comment::start "$FEATURE"
fi

# hashify NUM... — "#"-prefix a list of issue/task numbers for rendering as
# clickable references (e.g. "#502 #503"). A stray empty element never
# yields a bare "#".
hashify() {
  local out= n
  for n in "$@"; do
    [[ -n "$n" ]] && out+="#$n "
  done
  echo "${out% }"
}

# report MESSAGE — milestone narration always flows into the persistent,
# marker-anchored orchestration comment (one comment per feature, edited in
# place across runs). report() fires at most once per run, so for
# human-initiated runs it also resolves the transient per-run status comment
# right here: a multi-wave (or otherwise async) plan typically completes on a
# later, event-driven runner (COMMENT_ID=0) that never shares this run's
# /tmp id file, so this run's own completion is the only chance to take the
# transient "Running…" headline to done.
report() {
  local msg="$1"
  orchestrator_comment::upsert "$FEATURE" "$msg"
  local f; f=$(_status_comment::_id_file "$FEATURE")
  [[ -s "$f" ]] && status_comment::finish "$FEATURE"
  return 0
}

# --- Phase 2: Load and parse issue ---
ISSUE_DATA=$(its::get_issue "$FEATURE")
ISSUE_BODY=$(echo "$ISSUE_DATA" | jq -r '.body')
ISSUE_TITLE=$(echo "$ISSUE_DATA" | jq -r '.title')
ISSUE_LABELS=$(echo "$ISSUE_DATA" | jq -r '.labels[]')

# ── Definition of Ready: a completed tactical plan must exist (D6) ───
# Without `Tactics:done` there is nothing to orchestrate. Delegate to the
# Engineer (which itself delegates to the Architect when the design is
# missing) and re-queue execution behind it.
if ! echo "$ISSUE_LABELS" | grep -qx 'Tactics:done'; then
  if chain::dispatch_prerequisite "engineer" "execute" "${AUTO_CHAIN:-}" "$FEATURE"; then
    DELEGATE_MSG="This issue has no \`Tactics:done\` label, so the **Engineer** was dispatched first to produce the tactical plan. Execution resumes automatically when planning finishes."
    orchestrator_comment::upsert "$FEATURE" "🔁 **Not ready to execute** — $DELEGATE_MSG"
    _f=$(_status_comment::_id_file "$FEATURE")
    [[ -s "$_f" ]] && status_comment::delegate "$FEATURE"
    unset "_f"
    react_to_comment "${COMMENT_ID:-}" "+1" 2>/dev/null || true
    exit 0
  fi
  its::comment_issue "$FEATURE" "❌ \`$(autoducks_command_for execute)\`: issue is not ready (missing \`Tactics:done\`) and the Engineer could not be auto-dispatched (chain loop or depth limit). Run \`$(autoducks_command_for engineer)\` manually, then retry."
  _AUTODUCKS_NOTIFIED=1
  status_comment::fail "$FEATURE" 2>/dev/null || true
  react_to_comment "${COMMENT_ID:-}" "confused" 2>/dev/null || true
  exit 1
fi

# --- Phase 3: Ensure feature branch + draft PR (D7: the Maestro owns git) ---
progress_labels::ensure
SLUG=$(git::generate_slug "$FEATURE" "$ISSUE_TITLE")
BRANCH_PREFIX=$(branch_prefix_for_issue "$FEATURE")   # D10: feature/ or fix/
FEATURE_BRANCH="$BRANCH_PREFIX/$SLUG"

if ! git::branch_exists "$FEATURE_BRANCH" 2>/dev/null; then
  git::create_branch "$AUTODUCKS_BASE_BRANCH" "$FEATURE_BRANCH"
  for i in 1 2 3 4 5; do
    git::branch_exists "$FEATURE_BRANCH" 2>/dev/null && break
    sleep 1
  done
  its::remove_label "$FEATURE" "draft" 2>/dev/null || true
fi

EXISTING_FEATURE_PR=$(gh pr list --repo "$REPO" --head "$FEATURE_BRANCH" --base "$AUTODUCKS_INTEGRATION_BRANCH" --json number --jq '.[0].number // empty' 2>/dev/null || true)
if [[ -z "$EXISTING_FEATURE_PR" ]]; then
  PR_KIND="Feature"
  [[ "$BRANCH_PREFIX" == "fix" ]] && PR_KIND="Bug"
  git::create_pr "$FEATURE_BRANCH" "$AUTODUCKS_INTEGRATION_BRANCH" "$PR_KIND #$FEATURE: $ISSUE_TITLE" "Closes #$FEATURE" true || true
fi

ORCH_MODE=$(orchestrator_mode::resolve "$FEATURE")
log "Orchestrator mode: $ORCH_MODE"

# --- Phase 4: Single-task fast path (structural detection, D12) ---
# A tactical zone without a waves plan means the Engineer collapsed the plan
# into a single task carried by the feature issue itself.
PARSED=""
IS_SINGLE=false
if ! PARSED=$(parse_waves "$ISSUE_BODY" 2>/dev/null); then
  IS_SINGLE=true
fi

if [[ "$IS_SINGLE" == "true" ]]; then
  MERGED_PRS=$(git::list_merged_prs "$FEATURE_BRANCH")
  FEATURE_DONE=$(echo "$MERGED_PRS" \
    | jq -r '.[].body + " " + .[].title' \
    | grep -oiE '(fixes|closes|resolves)[[:space:]]+#[0-9]+' | grep -oE '[0-9]+' \
    | grep -qx "$FEATURE" && echo true || echo false)

  if [[ "$FEATURE_DONE" == "false" ]]; then
    progress_labels::start "$FEATURE" "Work:orchestrating" "Work:done"
    if prevent_duplicate_dispatch "$FEATURE" "$FEATURE_BRANCH"; then
      git::dispatch_workflow "autoducks-developer.yml" \
        -f "issue_number=$FEATURE" \
        -f "base_branch=$FEATURE_BRANCH" \
        ${COMMENTER:+-f "actor=$COMMENTER"} \
        ${WORKER_MODEL:+-f "model=$WORKER_MODEL"} \
        ${WORKER_EFFORT:+-f "effort=$WORKER_EFFORT"} \
        ${WORKER_MAX_TURNS:+-f "max_turns=$WORKER_MAX_TURNS"}
      report "**Single-task plan** — dispatched the Developer on the issue itself (no sub-tasks). The orchestrator finishes up when its PR merges."
    else
      report "**Single-task plan** — the Developer is already on it (task PR still open). No new dispatch needed; the orchestrator finishes up when its PR merges."
    fi
  else
    DELIVERED_CHILDREN="$(deliver_children "$FEATURE_BRANCH" "$FEATURE")"
    create_final_pr "$FEATURE" "$FEATURE_BRANCH" "$AUTODUCKS_INTEGRATION_BRANCH" "$ISSUE_TITLE" "$DELIVERED_CHILDREN" "$FEATURE"
    progress_labels::finish "$FEATURE" "Work:orchestrating" "Work:done"
    its::assign_issue "$FEATURE" "${COMMENTER:-}" 2>/dev/null || true
    report "🎉 **Single-task plan complete!** The PR is ready for review."
  fi

  react_to_comment "${COMMENT_ID:-}" "+1" 2>/dev/null || true
  exit 0
fi

# --- Phase 5: Multi-wave plan ---
declare -a WAVE_NAMES=()
declare -A WAVE_TASKS=()

while IFS='|' read -r type idx value; do
  case "$type" in
    WAVE) WAVE_NAMES[$idx]="$value" ;;
    TASK) WAVE_TASKS[$idx]+="$value " ;;
  esac
done <<< "$PARSED"

TOTAL_WAVES=${#WAVE_NAMES[@]}
[[ $TOTAL_WAVES -eq 0 ]] && die "No waves found in issue #$FEATURE"

if [[ "$ORCH_MODE" == "sequential" ]]; then
  declare -a _FLAT=()
  for ((w=0; w<TOTAL_WAVES; w++)); do
    for t in ${WAVE_TASKS[$w]:-}; do [[ -n "$t" ]] && _FLAT+=("$t"); done
  done
  WAVE_NAMES=(); declare -A _NEW_TASKS=()
  for i in "${!_FLAT[@]}"; do
    WAVE_NAMES[$i]="Task #${_FLAT[$i]}"
    _NEW_TASKS[$i]="${_FLAT[$i]} "
  done
  unset WAVE_TASKS; declare -A WAVE_TASKS
  for i in "${!_NEW_TASKS[@]}"; do WAVE_TASKS[$i]="${_NEW_TASKS[$i]}"; done
  TOTAL_WAVES=${#WAVE_NAMES[@]}
fi

log "Found $TOTAL_WAVES waves"

# --- Phase 6: Get done tasks from merged PRs ---
MERGED_PRS=$(git::list_merged_prs "$FEATURE_BRANCH")
declare -a DONE_TASKS=()

while IFS= read -r num; do
  [[ -n "$num" ]] && DONE_TASKS+=("$num")
done < <(echo "$MERGED_PRS" | jq -r '.[].body + " " + .[].title' | grep -oiE '(fixes|closes|resolves)[[:space:]]+#[0-9]+' | grep -oE '[0-9]+' | sort -u)

is_done() {
  local t="$1"
  for d in "${DONE_TASKS[@]:-}"; do
    [[ "$d" == "$t" ]] && return 0
  done
  return 1
}

# A no-code task never opens a sub-PR, so the merged-PR scan above can never
# mark it done — it would be re-dispatched forever. Union in plan tasks whose
# issue was closed as genuinely COMPLETED (not a human's not_planned/duplicate
# closure, which must NOT mask a task that still needs doing). its::get_issue
# doesn't expose state/stateReason, so query it directly (same gh issue view
# used for reviewer assignment further below).
for ((w=0; w<TOTAL_WAVES; w++)); do
  for t in ${WAVE_TASKS[$w]:-}; do
    [[ -z "$t" ]] && continue
    is_done "$t" && continue
    TASK_STATE=$(gh issue view "$t" --repo "$REPO" --json state,stateReason \
      --jq '(.state // "") + " " + (.stateReason // "")' 2>/dev/null || true)
    [[ "$TASK_STATE" == "CLOSED COMPLETED" ]] && DONE_TASKS+=("$t")
  done
done

log "Done tasks: ${DONE_TASKS[*]:-none}"

# Update checkboxes in the feature body
if [[ ${#DONE_TASKS[@]} -gt 0 ]]; then
  update_checkboxes "$FEATURE" "${DONE_TASKS[@]}"
fi

# --- Phase 7: Compute wave states ---
declare -a WAVE_STATES=()
for ((w=0; w<TOTAL_WAVES; w++)); do
  local_tasks=(${WAVE_TASKS[$w]:-})
  all_done=true
  for t in "${local_tasks[@]:-}"; do
    [[ -z "$t" ]] && continue
    is_done "$t" || { all_done=false; break; }
  done
  WAVE_STATES[$w]=$([[ "$all_done" == "true" ]] && echo "done" || echo "pending")
done

NEXT_WAVE=-1
for ((w=0; w<TOTAL_WAVES; w++)); do
  if [[ "${WAVE_STATES[$w]}" == "pending" ]]; then
    all_prev_done=true
    for ((p=0; p<w; p++)); do
      [[ "${WAVE_STATES[$p]}" != "done" ]] && { all_prev_done=false; break; }
    done
    if [[ "$all_prev_done" == "true" ]]; then
      NEXT_WAVE=$w
      break
    fi
  fi
done

# --- Phase 8: Act ---
if [[ $NEXT_WAVE -eq -1 ]]; then
  # Check if ALL waves done
  all_complete=true
  for ((w=0; w<TOTAL_WAVES; w++)); do
    [[ "${WAVE_STATES[$w]}" != "done" ]] && { all_complete=false; break; }
  done

  if [[ "$all_complete" == "true" ]]; then
    # All done — final PR if needed
    ALL_TASK_NUMS=()
    for ((w=0; w<TOTAL_WAVES; w++)); do
      for t in ${WAVE_TASKS[$w]:-}; do
        ALL_TASK_NUMS+=("$t")
      done
    done
    DELIVERED_CHILDREN="$(deliver_children "$FEATURE_BRANCH" "${ALL_TASK_NUMS[@]}")"
    FINAL_PR_NUM=$(create_final_pr "$FEATURE" "$FEATURE_BRANCH" "$AUTODUCKS_INTEGRATION_BRANCH" "$ISSUE_TITLE" "$DELIVERED_CHILDREN" "${ALL_TASK_NUMS[@]}")

    # Collect implementation summaries from merged task PRs
    WORKLOG=""

    for t in "${ALL_TASK_NUMS[@]}"; do
      [[ -z "$t" ]] && continue
      TASK_PR_DATA=$(echo "$MERGED_PRS" | jq -r \
        --arg t "$t" \
        '[.[] | select(.body | test("(?i)(fixes|closes|resolves)\\s+#" + $t + "\\b"))] | .[0] // empty')
      [[ -z "$TASK_PR_DATA" || "$TASK_PR_DATA" == "null" ]] && continue

      TASK_TITLE=$(echo "$TASK_PR_DATA" | jq -r '.title')
      TASK_BODY=$(echo "$TASK_PR_DATA" | jq -r '.body // ""')

      # Extract Implementation Summary section (from subtask PR body)
      IMPL_SUMMARY=$(echo "$TASK_BODY" | awk '
        /^## Implementation Summary/ { found=1; next }
        found && /^## /              { found=0 }
        found                        { print }
      ' | sed '/^[[:space:]]*$/d')

      if [[ -n "$IMPL_SUMMARY" ]]; then
        WORKLOG+="### $TASK_TITLE\n\n$IMPL_SUMMARY\n\n"
      fi
    done

    # Rebuild feature PR body: closes references + worklog
    CLOSES_BODY=""
    for t in "${ALL_TASK_NUMS[@]}"; do
      [[ -z "$t" ]] && continue
      CLOSES_BODY+="Closes #$t\n"
    done
    CLOSES_BODY+="Closes #$FEATURE"

    DELIVERED_CHILDREN_MARKER="$(metarepo::delivered_children_marker "$DELIVERED_CHILDREN")"
    if [[ -n "$DELIVERED_CHILDREN_MARKER" ]]; then
      CLOSES_BODY+="\n\n$DELIVERED_CHILDREN_MARKER"
    fi

    FULL_PR_BODY="$(echo -e "$CLOSES_BODY")"
    if [[ -n "$WORKLOG" ]]; then
      FULL_PR_BODY+="

## Work Log

$(echo -e "$WORKLOG")"
    fi

    git::update_pr_body "$FINAL_PR_NUM" "$FULL_PR_BODY"

    git::mark_pr_ready "$FINAL_PR_NUM" 2>/dev/null || true

    # Request review from feature issue assignees. Team-based reviewer
    # routing can hit the same `read:org` scope limitation as CODEOWNERS
    # expansion (see resolve-team.sh) — warn-and-continue so a missing
    # AUTODUCKS_ORG_TOKEN degrades to "no auto-assigned reviewer", never a
    # pipeline failure.
    ASSIGNEES=$(gh issue view "$FEATURE" --repo "$REPO" \
      --json assignees --jq '[.assignees[].login] | join(",")' 2>/dev/null || true)
    if [[ -n "$ASSIGNEES" ]]; then
      gh pr edit "$FINAL_PR_NUM" --repo "$REPO" \
        --add-reviewer "$ASSIGNEES" 2>/dev/null || true
    fi

    progress_labels::finish "$FEATURE" "Work:orchestrating" "Work:done"
    its::assign_issue "$FEATURE" "${COMMENTER:-}" 2>/dev/null || true
    if [[ "$ORCH_MODE" == "sequential" ]]; then
      report "🎉 **All $TOTAL_WAVES tasks complete!**

Every task has merged into the feature branch and the PR is ready.

**Next:** review and merge the PR to ship, or comment \`$(autoducks_command_for close)\`
to tear the pipeline artifacts down."
    else
      report "🎉 **All waves complete!**

Every task across all $TOTAL_WAVES waves has merged into the feature branch and
the PR is ready.

**Next:** review and merge the PR to ship, or comment \`$(autoducks_command_for close)\`
to tear the pipeline artifacts down."
    fi
  else
    # Blocked — not all previous waves done
    if [[ "$ORCH_MODE" == "sequential" ]]; then
      report "⏳ **Orchestrator waiting.**

An earlier task is still open, so the next task can't start yet. The
orchestrator re-runs automatically as task PRs merge — no action needed."
    else
      report "⏳ **Orchestrator waiting.**

Some tasks in an earlier wave are still open, so no new wave can start yet. The
orchestrator re-runs automatically as task PRs merge — no action needed."
    fi
  fi
else
  # Dispatch next wave
  log "Dispatching wave $NEXT_WAVE: ${WAVE_NAMES[$NEXT_WAVE]}"
  progress_labels::start "$FEATURE" "Work:orchestrating" "Work:done"
  ASSIGNED=()
  SKIPPED=()
  BLOCKED=()

  for t in ${WAVE_TASKS[$NEXT_WAVE]:-}; do
    [[ -z "$t" ]] && continue
    is_done "$t" && { SKIPPED+=("$t"); continue; }

    if ! prevent_duplicate_dispatch "$t" "$FEATURE_BRANCH" 2>/dev/null; then
      if task_blocked_pr_number "$t" "$FEATURE_BRANCH" &>/dev/null; then
        BLOCKED+=("$t")
      else
        SKIPPED+=("$t")
      fi
      continue
    fi

    git::dispatch_workflow "autoducks-developer.yml" \
      -f "issue_number=$t" \
      -f "base_branch=$FEATURE_BRANCH" \
      ${COMMENTER:+-f "actor=$COMMENTER"} \
      ${WORKER_MODEL:+-f "model=$WORKER_MODEL"} \
      ${WORKER_EFFORT:+-f "effort=$WORKER_EFFORT"} \
      ${WORKER_MAX_TURNS:+-f "max_turns=$WORKER_MAX_TURNS"}

    ASSIGNED+=("$t")
  done

  # Post summary
  if [[ "$ORCH_MODE" == "sequential" ]]; then
    TASK_NUM=$(echo "${WAVE_TASKS[$NEXT_WAVE]:-}" | xargs)
    SUMMARY="➡️ **Task $((NEXT_WAVE+1)) of $TOTAL_WAVES dispatched: #${TASK_NUM}**\n\n"
  else
    SUMMARY="🌊 **Wave $((NEXT_WAVE+1)) of $TOTAL_WAVES dispatched: ${WAVE_NAMES[$NEXT_WAVE]}**\n\n"
  fi
  [[ ${#ASSIGNED[@]} -gt 0 ]] && SUMMARY+="**Dispatched:** $(hashify "${ASSIGNED[@]}")\n"
  [[ ${#SKIPPED[@]} -gt 0 ]] && SUMMARY+="**Skipped (already done or in flight):** $(hashify "${SKIPPED[@]}")\n"
  [[ ${#BLOCKED[@]} -gt 0 ]] && SUMMARY+="**Blocked — needs \`$(autoducks_command_for fix)\`:** $(hashify "${BLOCKED[@]}")\n"
  SUMMARY+="\nThe orchestrator advances automatically as each task PR merges.\n"

  report "$(echo -e "$SUMMARY")"
fi

react_to_comment "${COMMENT_ID:-}" "+1" 2>/dev/null || true
