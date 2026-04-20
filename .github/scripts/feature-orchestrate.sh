#!/usr/bin/env bash
# =============================================================================
# Feature Orchestrator — Deterministic Shell Implementation
# =============================================================================
#
# PURPOSE
# -------
# Advances a feature issue implementation plan. Reads the plan from a YAML block
# in the feature issue body, checks merged PRs, updates checkboxes, assigns the
# next ready wave of tasks, and opens the final PR when everything is done.
#
# No LLM involved — entirely deterministic.
#
# REQUIRED ENV VARS
# -----------------
# GH_TOKEN            GitHub token with repo + actions write access
# GITHUB_EVENT_NAME   workflow_dispatch | issue_comment | issues | pull_request
# REPO                owner/name
# FEATURE_INPUT          feature issue number (for workflow_dispatch)
# ISSUE_NUMBER        issue number (for issue_comment / issues events)
# PR_BASE_REF         base ref (for pull_request events)
#
# FEATURE ISSUE BODY FORMAT
# ----------------------
# The feature issue body uses natural markdown. The parser is lenient:
#
#   ## Wave 1 — Foundation
#   - [ ] #1 Project Bootstrap `P0`
#   - [ ] #2 Data Model `P0`
#
#   ## Wave 2: Core
#   - [ ] #3 Router `P0`
#   - [ ] #5 Token Management `P0`
#
#   ### Wave 3 (Parallel Adapters)
#   - [ ] #6 Slack `P1`
#   - [ ] #7 Discord `P2`
#
# Rules:
#   - Any non-checkbox line containing "Wave <number>" (case-insensitive)
#     opens a new wave. Heading style doesn't matter (##, ###, **bold**,
#     plain text — all work). Separators after "Wave N" are stripped
#     (":", "—", "-", "(", etc.) to extract the wave name.
#   - Any line matching `- [ ] #N` or `- [x] #N` (or `* [ ] #N`) is a task
#     assigned to the most recent wave.
#   - Task state (checked/unchecked) is NOT used — the orchestrator derives
#     state from merged PRs, not from the checkbox marks in the body.
#     The body's checkboxes are updated by the orchestrator based on merges.
#   - Any other markdown (intros, notes, headings) is preserved and ignored.
# =============================================================================

set -euo pipefail

log() { echo "[feature] $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# Trap failures and notify the feature issue if we know which one
FEATURE=""
report_failure() {
  local exit_code=$?
  if [[ -n "$FEATURE" ]]; then
    gh issue comment "$FEATURE" --body "⚠️ **Feature orchestrator failed** (exit $exit_code)

- **Run:** https://github.com/$REPO/actions/runs/${GITHUB_RUN_ID:-unknown}
- **Event:** $GITHUB_EVENT_NAME
- **Action needed:** Comment \`/agents start\` on this issue to retry." 2>/dev/null || true
  fi
  exit $exit_code
}
trap report_failure ERR

# -----------------------------------------------------------------------------
# 1. Determine feature issue number from event context
# -----------------------------------------------------------------------------
determine_feature() {
  case "$GITHUB_EVENT_NAME" in
    workflow_dispatch)
      echo "${FEATURE_INPUT:-}"
      ;;
    issue_comment|issues)
      echo "${ISSUE_NUMBER:-}"
      ;;
    pull_request)
      echo "${PR_BASE_REF:-}" | grep -oP 'feature/\K\d+' || echo ""
      ;;
    *)
      die "Unknown event: $GITHUB_EVENT_NAME"
      ;;
  esac
}

FEATURE=$(determine_feature)
[[ -n "$FEATURE" ]] || die "Could not determine feature issue number from event"
log "Feature issue: #$FEATURE"

# -----------------------------------------------------------------------------
# 2. Load feature issue and parse markdown wave structure
# -----------------------------------------------------------------------------
ISSUE_JSON=$(gh issue view "$FEATURE" --json body,title,labels)
ISSUE_BODY=$(echo "$ISSUE_JSON" | jq -r '.body')
ISSUE_TITLE=$(echo "$ISSUE_JSON" | jq -r '.title')
HAS_META_LABEL=$(echo "$ISSUE_JSON" | jq -r '.labels[].name' | grep -qx "feature" && echo "yes" || echo "no")

[[ "$HAS_META_LABEL" == "yes" ]] || die "Issue #$FEATURE does not have 'feature' label"

# Parse wave structure. Two formats supported:
# 1. YAML code block (preferred — explicit and unambiguous):
#    ```yaml
#    waves:
#      - name: Foundation
#        tasks: [1]
#      - name: Core
#        tasks: [2, 3]
#    ```
# 2. Markdown headings (fallback — natural for humans):
#    ## Wave 1 — Foundation
#    - [ ] #1 Bootstrap
# The script tries YAML first. If no valid YAML plan is found, it falls
# back to markdown parsing. Output: "WAVE|<idx>|<name>" and "TASK|<idx>|<num>".

parse_yaml_plan() {
  local body="$1"
  # Extract first ```yaml ... ``` block
  local yaml_block
  yaml_block=$(echo "$body" | awk '/^```yaml[[:space:]]*$/{flag=1;next}/^```[[:space:]]*$/{flag=0}flag')
  [[ -n "$yaml_block" ]] || return 1

  # Check it has a `waves:` key
  echo "$yaml_block" | grep -q '^waves:' || return 1

  # Verify yq can parse it and it has at least one wave
  local num_waves
  num_waves=$(echo "$yaml_block" | yq '.waves | length' 2>/dev/null || echo "")
  [[ -n "$num_waves" && "$num_waves" != "null" && "$num_waves" -gt 0 ]] || return 1

  # Emit in the same format as the markdown parser
  local i
  for ((i=0; i<num_waves; i++)); do
    local name tasks
    name=$(echo "$yaml_block" | yq -r ".waves[$i].name // \"Wave $((i+1))\"")
    printf "WAVE|%d|%s\n" "$((i+1))" "$name"
    while IFS= read -r t; do
      [[ -n "$t" && "$t" != "null" ]] && printf "TASK|%d|%s\n" "$((i+1))" "$t"
    done < <(echo "$yaml_block" | yq -r ".waves[$i].tasks[]" 2>/dev/null)
  done
  return 0
}

parse_markdown_plan() {
  local body="$1"
  # A wave heading is a line that:
  # - Starts with a heading marker (#, *, or the word "Wave" itself)
  # - Contains "Wave <N>"
  # - Is NOT a checkbox line
  # This prevents inline mentions like "Wave 2 depends on Wave 1" from
  # being mistakenly parsed as wave headings.
  echo "$body" | awk '
    /^(#|\*|[Ww]ave)/ && /[Ww]ave[[:space:]]+[0-9]+/ && !/^[[:space:]]*[-*][[:space:]]+\[/ {
      wave++
      name = ""
      if (match($0, /[Ww]ave[[:space:]]+[0-9]+/)) {
        rest = substr($0, RSTART + RLENGTH)
        gsub(/^[[:space:]]*[:——\-\*\(]+[[:space:]]*/, "", rest)
        gsub(/[\)\*]+[[:space:]]*$/, "", rest)
        gsub(/[[:space:]]+$/, "", rest)
        name = rest
      }
      if (name == "") name = "Wave " wave
      printf "WAVE|%d|%s\n", wave, name
      next
    }
    wave >= 1 && /^[[:space:]]*[-*][[:space:]]+\[[xX[:space:]]\][[:space:]]+#[0-9]+/ {
      if (match($0, /#[0-9]+/)) {
        num = substr($0, RSTART+1, RLENGTH-1)
        printf "TASK|%d|%s\n", wave, num
      }
    }
  '
}

# Try YAML first, fall back to markdown
PARSED=""
if PARSED=$(parse_yaml_plan "$ISSUE_BODY") && [[ -n "$PARSED" ]]; then
  log "Parsed plan from YAML block"
else
  PARSED=$(parse_markdown_plan "$ISSUE_BODY")
  [[ -n "$PARSED" ]] && log "Parsed plan from markdown headings"
fi

[[ -n "$PARSED" ]] || die "Feature issue body has no wave structure. Accepted formats: (1) \`\`\`yaml\`\`\` block with 'waves:' key, or (2) markdown headings like '## Wave 1 — Name' followed by '- [ ] #N' checkbox lines."

# Build WAVE_NAMES and WAVE_TASKS arrays from parsed output
declare -a WAVE_NAMES_BY_IDX=()     # index 0-based → name
declare -a WAVE_TASKS_BY_IDX=()     # index 0-based → space-separated task numbers

while IFS='|' read -r kind idx rest; do
  case "$kind" in
    WAVE)
      i=$((idx - 1))
      WAVE_NAMES_BY_IDX[$i]="$rest"
      WAVE_TASKS_BY_IDX[$i]=""
      ;;
    TASK)
      i=$((idx - 1))
      if [[ -z "${WAVE_TASKS_BY_IDX[$i]}" ]]; then
        WAVE_TASKS_BY_IDX[$i]="$rest"
      else
        WAVE_TASKS_BY_IDX[$i]="${WAVE_TASKS_BY_IDX[$i]} $rest"
      fi
      ;;
  esac
done <<< "$PARSED"

NUM_WAVES=${#WAVE_NAMES_BY_IDX[@]}
[[ $NUM_WAVES -gt 0 ]] || die "No waves parsed from feature issue body"
log "Plan has $NUM_WAVES waves"
for ((i=0; i<NUM_WAVES; i++)); do
  log "  Wave $((i+1)) [${WAVE_NAMES_BY_IDX[$i]}]: ${WAVE_TASKS_BY_IDX[$i]:-<empty>}"
done

# -----------------------------------------------------------------------------
# 3. Ensure feature branch exists
# -----------------------------------------------------------------------------
BRANCH="feature/$FEATURE"
# Use exit code (not output) to check branch existence — more robust than
# parsing `gh api --jq '.ref'` output, which can return "null" string on 404.
FIRST_RUN=false
if gh api "repos/$REPO/git/refs/heads/$BRANCH" &>/dev/null; then
  log "Branch $BRANCH already exists"
else
  log "Creating branch $BRANCH from main"
  MAIN_SHA=$(gh api "repos/$REPO/git/refs/heads/main" --jq '.object.sha')
  gh api "repos/$REPO/git/refs" -X POST -f ref="refs/heads/$BRANCH" -f sha="$MAIN_SHA" >/dev/null
  FIRST_RUN=true

  # Wait for the branch to be visible to subsequent API calls (replication lag).
  # Without this, task workers dispatched right after may fail to checkout.
  for i in 1 2 3 4 5; do
    if gh api "repos/$REPO/git/refs/heads/$BRANCH" &>/dev/null; then
      log "Branch $BRANCH is visible (attempt $i)"
      break
    fi
    log "Waiting for branch $BRANCH to propagate (attempt $i)..."
    sleep 1
  done
fi

# Kickstart-time side effect: drop the `draft` label if the plan-agent left
# it on the feature issue. Once the orchestrator has committed to running,
# `/agents plan` revisions should be blocked — removing `draft` does that
# via the claude-plan.yml trigger filter. Silent no-op for manually-
# authored feature issues that never had `draft`.
gh issue edit "$FEATURE" --remove-label draft 2>/dev/null || true

# -----------------------------------------------------------------------------
# 4. Get merged PRs targeting the feature branch → derive done tasks
# -----------------------------------------------------------------------------
MERGED_PRS=$(gh pr list --repo "$REPO" --state merged --base "$BRANCH" --json number,body,title --limit 100)

declare -a DONE_TASKS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && DONE_TASKS+=("$line")
done < <(echo "$MERGED_PRS" | jq -r '.[] | (.body // "") + " " + (.title // "")' | grep -oiP '(?:fixes|closes|resolves)\s+#\K\d+' | sort -u)

log "Done tasks (from merged PRs): ${DONE_TASKS[*]:-none}"

# Helper: is task done?
is_done() {
  local t=$1
  for d in "${DONE_TASKS[@]}"; do
    [[ "$d" == "$t" ]] && return 0
  done
  return 1
}

# -----------------------------------------------------------------------------
# 5. Update checkboxes in feature issue body
# -----------------------------------------------------------------------------
NEW_BODY="$ISSUE_BODY"
CHANGED=false
for t in "${DONE_TASKS[@]}"; do
  # Match "- [ ] #N " or "- [ ] #N$" — the trailing char must not be a digit
  BEFORE=$(echo "$NEW_BODY" | wc -c)
  NEW_BODY=$(echo "$NEW_BODY" | perl -pe "s/^- \\[ \\] #${t}(?!\\d)/- [x] #${t}/g")
  AFTER=$(echo "$NEW_BODY" | wc -c)
  [[ "$BEFORE" != "$AFTER" || "$NEW_BODY" != "$ISSUE_BODY" ]] && CHANGED=true
done

if [[ "$CHANGED" == "true" ]]; then
  log "Updating feature issue body with new checkboxes"
  # Use a temp file to handle multiline body safely
  TMPFILE=$(mktemp)
  echo "$NEW_BODY" > "$TMPFILE"
  gh issue edit "$FEATURE" --body-file "$TMPFILE" >/dev/null
  rm -f "$TMPFILE"
  ISSUE_BODY="$NEW_BODY"
fi

# -----------------------------------------------------------------------------
# 6. Compute wave states
# -----------------------------------------------------------------------------
declare -a WAVE_STATE=()  # "done" | "pending"
declare -a WAVE_NAMES=()

for ((i=0; i<NUM_WAVES; i++)); do
  NAME="${WAVE_NAMES_BY_IDX[$i]}"
  TASKS="${WAVE_TASKS_BY_IDX[$i]}"

  ALL_DONE=true
  for t in $TASKS; do
    if ! is_done "$t"; then
      ALL_DONE=false
      break
    fi
  done

  WAVE_NAMES+=("$NAME")
  if $ALL_DONE; then
    WAVE_STATE+=("done")
  else
    WAVE_STATE+=("pending")
  fi
done

# -----------------------------------------------------------------------------
# 7. Find the next ready wave
# -----------------------------------------------------------------------------
# "Ready" = all previous waves are done, and this wave has pending tasks.
NEXT_WAVE=-1
for ((i=0; i<NUM_WAVES; i++)); do
  if [[ "${WAVE_STATE[$i]}" == "pending" ]]; then
    READY=true
    for ((j=0; j<i; j++)); do
      if [[ "${WAVE_STATE[$j]}" != "done" ]]; then
        READY=false
        break
      fi
    done
    if $READY; then
      NEXT_WAVE=$i
      break
    fi
  fi
done

# -----------------------------------------------------------------------------
# 8. Act on state
# -----------------------------------------------------------------------------

# Case A: all waves done → open final PR if not already open
ALL_WAVES_DONE=true
for s in "${WAVE_STATE[@]}"; do
  [[ "$s" != "done" ]] && { ALL_WAVES_DONE=false; break; }
done

if $ALL_WAVES_DONE; then
  log "All waves complete"
  EXISTING_FINAL=$(gh pr list --repo "$REPO" --head "$BRANCH" --base main --state all --json number --jq '.[0].number // empty')
  if [[ -n "$EXISTING_FINAL" ]]; then
    log "Final PR #$EXISTING_FINAL already exists"
    FINAL_PR="#$EXISTING_FINAL"
  else
    log "Opening final PR $BRANCH → main"
    # Use `Closes #N` syntax for every task issue and the feature issue itself —
    # GitHub auto-closes them when this PR merges into the default branch.
    # (Task PRs target `feature/*`, not `main`, so their own `fixes #N` bodies
    # don't auto-close anything. The final PR is the only merge-into-main
    # event, so it must carry all the closure directives.)
    FINAL_BODY=$(cat <<EOF
## Summary

All tasks in feature issue #$FEATURE are complete:

$(for t in "${DONE_TASKS[@]}"; do echo "- Closes #$t"; done)

Closes #$FEATURE

🎉 Implementation roadmap complete.
EOF
)
    FINAL_URL=$(gh pr create --repo "$REPO" --base main --head "$BRANCH" \
      --title "Feature #$FEATURE: $ISSUE_TITLE" --body "$FINAL_BODY")
    FINAL_PR="$FINAL_URL"
  fi

  gh issue comment "$FEATURE" --body "## Orchestrator Update — Complete 🎉

All waves done. Final PR: $FINAL_PR" >/dev/null
  exit 0
fi

# Case B: no wave ready (blocked or in progress) → just post status
if [[ $NEXT_WAVE -eq -1 ]]; then
  log "No ready wave (blocked waiting on pending tasks)"
  STATUS_LINES=""
  for ((i=0; i<NUM_WAVES; i++)); do
    ICON="⏳"
    [[ "${WAVE_STATE[$i]}" == "done" ]] && ICON="✅"
    STATUS_LINES+="- $ICON **${WAVE_NAMES[$i]}**: ${WAVE_STATE[$i]}"$'\n'
  done

  gh issue comment "$FEATURE" --body "## Orchestrator Update

$STATUS_LINES
Done tasks so far: ${DONE_TASKS[*]:-none}" >/dev/null
  exit 0
fi

# Case C: assign next wave
log "Assigning wave $((NEXT_WAVE+1)): ${WAVE_NAMES[$NEXT_WAVE]}"
NEXT_TASKS="${WAVE_TASKS_BY_IDX[$NEXT_WAVE]}"

declare -a ASSIGNED=()
declare -a SKIPPED=()
for t in $NEXT_TASKS; do
  # Skip if task is already done (shouldn't happen, but defensive)
  if is_done "$t"; then
    continue
  fi

  # Skip if task already has an open PR against this branch
  OPEN_PR=$(gh pr list --repo "$REPO" --base "$BRANCH" --state open --json number,body,title \
    --jq "[.[] | select((.body // \"\") + \" \" + (.title // \"\") | test(\"(?i)(fixes|closes|resolves)\\\\s+#$t([^0-9]|$)\"))] | .[0].number // empty")
  if [[ -n "$OPEN_PR" ]]; then
    log "Task #$t already has open PR #$OPEN_PR — skipping"
    SKIPPED+=("#$t (open PR #$OPEN_PR)")
    continue
  fi

  # Check if there's an in-progress or queued task worker run for this issue
  EXISTING_RUN=$(gh run list --repo "$REPO" --workflow=claude-task.yml \
    --status=in_progress --json databaseId,displayTitle --limit 20 \
    --jq "[.[] | select(.displayTitle | contains(\"#$t\"))] | .[0].databaseId // empty" 2>/dev/null || echo "")
  if [[ -n "$EXISTING_RUN" ]]; then
    log "Task #$t already has in-progress run #$EXISTING_RUN — skipping"
    SKIPPED+=("#$t (run in progress)")
    continue
  fi

  # Determine priority (for auto-merge flag)
  PRIORITY=$(gh issue view "$t" --repo "$REPO" --json labels --jq '.labels[].name' | grep -oP 'priority:P\K\d' | head -1 || echo "")

  # Post informational comment on task issue (visible trail for humans).
  # NOTE: this comment does NOT trigger the task worker — GITHUB_TOKEN comments
  # are silent to workflow events. The assignment comment is informational.
  COMMENT="Task dispatched. Implementing this issue.
- Base branch: \`$BRANCH\`
- Target your PR to \`$BRANCH\`
- Include \`fixes #$t\` in the PR body"
  if [[ "$PRIORITY" == "0" ]]; then
    COMMENT="$COMMENT
- This is P0 — auto-merge is enabled."
  fi
  gh issue comment "$t" --repo "$REPO" --body "$COMMENT" >/dev/null

  # Actually trigger the task worker via workflow_dispatch.
  # This is reliable because workflow_dispatch IS allowed from GITHUB_TOKEN.
  # $WORKER_MODEL and $WORKER_REASONING are optional — inherited from the
  # `/agents start` directive if present, otherwise the task worker applies
  # its own defaults.
  DISPATCH_ARGS=(-f "issue_number=$t" -f "base_branch=$BRANCH")
  [[ -n "${WORKER_MODEL:-}" ]]     && DISPATCH_ARGS+=(-f "model=$WORKER_MODEL")
  [[ -n "${WORKER_REASONING:-}" ]] && DISPATCH_ARGS+=(-f "reasoning=$WORKER_REASONING")
  gh workflow run claude-task.yml --repo "$REPO" "${DISPATCH_ARGS[@]}" >/dev/null

  ASSIGNED+=("#$t")
  log "Assigned and dispatched task #$t"
done

# -----------------------------------------------------------------------------
# 9. Post summary on feature issue
# -----------------------------------------------------------------------------
SUMMARY=$(cat <<EOF
## Orchestrator Update

**Wave:** ${WAVE_NAMES[$NEXT_WAVE]} ($((NEXT_WAVE+1)) of $NUM_WAVES)

### Marked done (since last run)
$(if [[ ${#DONE_TASKS[@]} -eq 0 ]]; then echo "_none yet_"; else for t in "${DONE_TASKS[@]}"; do echo "- [x] #$t"; done | sort -u; fi)

### Assigned now
$(if [[ ${#ASSIGNED[@]} -eq 0 ]]; then echo "_nothing new to assign_"; else for a in "${ASSIGNED[@]}"; do echo "- $a"; done; fi)

### Skipped
$(if [[ ${#SKIPPED[@]} -eq 0 ]]; then echo "_none_"; else for s in "${SKIPPED[@]}"; do echo "- $s"; done; fi)

### Wave status
$(for ((i=0; i<NUM_WAVES; i++)); do
  ICON="⏳"
  [[ "${WAVE_STATE[$i]}" == "done" ]] && ICON="✅"
  [[ $i -eq $NEXT_WAVE ]] && ICON="▶️"
  echo "- $ICON **${WAVE_NAMES[$i]}**"
done)
EOF
)

gh issue comment "$FEATURE" --body "$SUMMARY" >/dev/null
log "Done"
