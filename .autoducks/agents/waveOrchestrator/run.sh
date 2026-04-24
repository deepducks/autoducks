#!/usr/bin/env bash
set -euo pipefail
export AUTODUCKS_AGENT="waveOrchestrator"
source "$(dirname "${BASH_SOURCE[0]}")/../../core/config/load-config.sh"
source "$AUTODUCKS_ROOT/core/feedback/react-to-comment.sh"
source "$AUTODUCKS_ROOT/core/feedback/notify-failure.sh"
source "$AUTODUCKS_ROOT/core/feedback/update-checkboxes.sh"
source "$AUTODUCKS_ROOT/core/orchestration/parse-waves.sh"
source "$AUTODUCKS_ROOT/core/orchestration/prevent-duplicate-dispatch.sh"

log() { echo "[wave-orchestrator] $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

trap 'notify_failure "$FEATURE" "$RUN_ID" 2>/dev/null || true; exit 1' ERR

react_to_comment "${COMMENT_ID:-}" "eyes"

# --- Phase 1: Determine feature issue ---
FEATURE="${FEATURE_ISSUE:?FEATURE_ISSUE env var required}"

# --- Phase 2: Load and parse issue ---
ISSUE_DATA=$(its::get_issue "$FEATURE")
ISSUE_BODY=$(echo "$ISSUE_DATA" | jq -r '.body')
ISSUE_TITLE=$(echo "$ISSUE_DATA" | jq -r '.title')
ISSUE_LABELS=$(echo "$ISSUE_DATA" | jq -r '.labels[]')

PARSED=$(parse_waves "$ISSUE_BODY") || die "Could not parse waves from issue #$FEATURE"

# Build arrays from parsed output
declare -a WAVE_NAMES=()
declare -A WAVE_TASKS=()

while IFS='|' read -r type idx value; do
  case "$type" in
    WAVE) WAVE_NAMES[$idx]="$value" ;;
    TASK)  WAVE_TASKS[$idx]+="$value " ;;
  esac
done <<< "$PARSED"

TOTAL_WAVES=${#WAVE_NAMES[@]}
[[ $TOTAL_WAVES -eq 0 ]] && die "No waves found in issue #$FEATURE"

log "Found $TOTAL_WAVES waves"

# --- Phase 3: Ensure feature branch ---
SLUG=$(git::generate_slug "$FEATURE" "$ISSUE_TITLE")
FEATURE_BRANCH="feature/$SLUG"

if ! git::branch_exists "$FEATURE_BRANCH" 2>/dev/null; then
  git::create_branch "$AUTODUCKS_BASE_BRANCH" "$FEATURE_BRANCH"
  for i in 1 2 3 4 5; do
    git::branch_exists "$FEATURE_BRANCH" 2>/dev/null && break
    sleep 1
  done
  its::remove_label "$FEATURE" "draft" 2>/dev/null || true
fi

# --- Phase 4: Get done tasks from merged PRs ---
MERGED_PRS=$(git::list_merged_prs "$FEATURE_BRANCH")
declare -a DONE_TASKS=()

while IFS= read -r num; do
  [[ -n "$num" ]] && DONE_TASKS+=("$num")
done < <(echo "$MERGED_PRS" | jq -r '.[].body + " " + .[].title' | grep -oiP '(?:fixes|closes|resolves)\s+#\K\d+' | sort -u)

is_done() {
  local t="$1"
  for d in "${DONE_TASKS[@]:-}"; do
    [[ "$d" == "$t" ]] && return 0
  done
  return 1
}

log "Done tasks: ${DONE_TASKS[*]:-none}"

# --- Phase 5: Update checkboxes ---
if [[ ${#DONE_TASKS[@]} -gt 0 ]]; then
  update_checkboxes "$FEATURE" "${DONE_TASKS[@]}"
fi

# --- Phase 6: Compute wave states ---
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

# --- Phase 7: Find next ready wave ---
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
  # Check if ALL waves are done
  all_complete=true
  for ((w=0; w<TOTAL_WAVES; w++)); do
    [[ "${WAVE_STATES[$w]}" != "done" ]] && { all_complete=false; break; }
  done

  if [[ "$all_complete" == "true" ]]; then
    # All done — create final PR if needed
    EXISTING_PR=$(gh pr list --repo "$REPO" --head "$FEATURE_BRANCH" --base "$AUTODUCKS_BASE_BRANCH" --state all --json number --jq '.[0].number // empty' 2>/dev/null || true)

    if [[ -z "$EXISTING_PR" ]]; then
      # Build closes references
      ALL_TASKS=""
      for ((w=0; w<TOTAL_WAVES; w++)); do
        for t in ${WAVE_TASKS[$w]:-}; do
          ALL_TASKS+="Closes #$t\n"
        done
      done
      ALL_TASKS+="Closes #$FEATURE"

      git::create_pr "$FEATURE_BRANCH" "$AUTODUCKS_BASE_BRANCH" "Feature #$FEATURE: $ISSUE_TITLE" "$(echo -e "$ALL_TASKS")"
    fi

    its::comment_issue "$FEATURE" "**All waves complete!** The feature PR is ready for review."
  else
    # Blocked — not all previous waves done
    its::comment_issue "$FEATURE" "**Orchestrator update:** Waves are in progress. Waiting for dependencies to complete."
  fi
else
  # Dispatch next wave
  log "Dispatching wave $NEXT_WAVE: ${WAVE_NAMES[$NEXT_WAVE]}"
  ASSIGNED=()
  SKIPPED=()

  for t in ${WAVE_TASKS[$NEXT_WAVE]:-}; do
    [[ -z "$t" ]] && continue
    is_done "$t" && { SKIPPED+=("$t"); continue; }

    if ! prevent_duplicate_dispatch "$t" "$FEATURE_BRANCH" "autoducks-execute.yml" 2>/dev/null; then
      SKIPPED+=("$t")
      continue
    fi

    git::dispatch_workflow "autoducks-execute.yml" \
      -f "issue_number=$t" \
      -f "base_branch=$FEATURE_BRANCH" \
      ${WORKER_MODEL:+-f "model=$WORKER_MODEL"} \
      ${WORKER_REASONING:+-f "reasoning=$WORKER_REASONING"}

    ASSIGNED+=("$t")
  done

  # Post summary
  SUMMARY="**Wave $((NEXT_WAVE+1)): ${WAVE_NAMES[$NEXT_WAVE]}**\n\n"
  [[ ${#ASSIGNED[@]} -gt 0 ]] && SUMMARY+="**Dispatched:** ${ASSIGNED[*]}\n"
  [[ ${#SKIPPED[@]} -gt 0 ]] && SUMMARY+="**Skipped:** ${SKIPPED[*]}\n"

  its::comment_issue "$FEATURE" "$(echo -e "$SUMMARY")"
fi

react_to_comment "${COMMENT_ID:-}" "+1" 2>/dev/null || true
