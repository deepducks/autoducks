#!/usr/bin/env bash
# =============================================================================
# Smoke Test — Plan Pipeline Validator
# =============================================================================
#
# PURPOSE
# -------
# Exercises the parts of the workflow trio that scripts/smoke-test.sh skips:
#
#   1. /agents devise end-to-end (questions-free draft → plan written → task
#      issues created → labels/type/sub-issues applied).
#   2. GitHub native issue types (Feature on the draft, Task on each child).
#   3. Sub-issue relationships (children linked under the feature).
#   4. /agents revert (closes tasks, strips labels, deletes comments,
#      restores the body from userContentEdits history).
#   5. Per-comment reactions 👀 + 👍 (both /agents devise and /agents revert).
#
# COST
# ----
# Runs one tactical-agent call at `sonnet low` reasoning to keep it cheap.
# Expected wall time: 3–6 min. No task worker is triggered — this test
# covers the planning half of the pipeline, not the shipping half.
#
# USAGE
# -----
#   ./scripts/smoke-test-plan.sh [OPTIONS]
#
# OPTIONS
#   --keep          Do not run /agents revert at the end (leaves the
#                   feature + task issues in place for manual inspection).
#   --no-wait       Create the seed issue and kickstart /agents devise,
#                   don't wait for completion.
#   --repo OWNER/REPO  Target repo (default: current repo from `gh`).
#   -h, --help      Show this help.
#
# ASSERTIONS (SOFT vs HARD)
# -------------------------
# Hard assertions (fail the test if violated):
#   - /agents devise run completes with success
#   - Feature issue receives `Ready` label
#   - Issue body changes (plan written into it)
#   - At least 1 task issue created with `priority:P*` label
#   - /agents revert closes all task issues and strips labels
#
# Soft assertions (logged as warning if violated, test still passes):
#   - Issue type = Feature on the draft, Task on children
#     (requires org-level issue-type configuration)
#   - Sub-issue links exist (requires sub-issues API enabled)
#   - 👀 reaction on /agents devise comment (may miss if reaction races)
#   - Body reverts to original (requires userContentEdits coverage)
# =============================================================================

set -euo pipefail

KEEP=false
WAIT=true
REPO=""
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep) KEEP=true; shift ;;
    --no-wait) WAIT=false; shift ;;
    --repo) REPO="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,60p' "$0"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

REPO_ARG=""
if [[ -n "$REPO" ]]; then
  REPO_ARG="--repo $REPO"
else
  REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
fi

echo "=== Smoke Test — Plan Pipeline ==="
echo "Repo: $REPO"
echo "Timestamp: $TIMESTAMP"
echo ""

FAIL=0
WARN=0
pass() { echo "  ✅ $1"; }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }
warn() { echo "  ⚠️  $1"; WARN=$((WARN + 1)); }

# Poll a comment's reactions for the terminal signal every workflow posts:
#   +1       → success
#   confused → failure
# Scoped to the specific comment, so it's immune to GitHub's occasional
# double-fire on issue_comment (the skipped duplicate never touches
# reactions) and safe with parallel workflows on other issues (they
# post on their own comments). Returns 0=success, 1=failure, 2=timeout.
# NOTE: not usable for /agents revert or /agents close — those
# workflows delete the triggering comment before completing. Use
# wait_for_feature_unplanned / wait_for_feature_closed for those.
wait_for_reaction() {
  local comment_id="$1"
  local timeout_s="$2"
  local label="$3"
  local interval=10
  local waited=0
  local reactions=""
  while [[ $waited -lt $timeout_s ]]; do
    reactions=$(gh api "repos/$REPO/issues/comments/$comment_id/reactions" \
      --jq '[.[].content] | join(",")' 2>/dev/null || echo "")
    case ",$reactions," in
      *,+1,*)       return 0 ;;
      *,confused,*) return 1 ;;
    esac
    sleep $interval
    waited=$((waited + interval))
    if [[ $((waited % 60)) -eq 0 ]]; then
      echo "  ... $label ${waited}/${timeout_s}s (reactions: ${reactions:-none})"
    fi
  done
  return 2
}

# Poll a feature issue until both terminal invariants of /agents revert
# are satisfied: `Ready`+`draft` labels stripped AND all comments
# deleted. We check both because the workflow removes labels first and
# deletes comments last, so waiting on labels alone returns too early
# and races with the comment-count assertion downstream. Used instead
# of reaction-polling because revert deletes its own trigger comment.
# Issue-scoped — parallel reverts on other features don't cross-talk.
# Returns 0=both invariants satisfied, 2=timeout.
wait_for_feature_unplanned() {
  local issue="$1"
  local timeout_s="$2"
  local interval=5
  local waited=0
  local labels=""
  local comments="?"
  while [[ $waited -lt $timeout_s ]]; do
    labels=$(gh api "repos/$REPO/issues/$issue" \
      --jq '[.labels[].name] | join(",")' 2>/dev/null || echo "?")
    comments=$(gh api "repos/$REPO/issues/$issue/comments" \
      --jq '. | length' 2>/dev/null || echo "?")
    local labels_clean=1
    case ",$labels," in
      *,Ready,*|*,draft,*) labels_clean=0 ;;
    esac
    if [[ "$labels_clean" == "1" && "$comments" == "0" ]]; then
      return 0
    fi
    sleep $interval
    waited=$((waited + interval))
    if [[ $((waited % 30)) -eq 0 ]]; then
      echo "  ... revert ${waited}/${timeout_s}s (labels: ${labels:-none}, comments: $comments)"
    fi
  done
  return 2
}

# --- Ensure labels exist (plan agent creates priority:P* lazily but we
#     want them ready so we can assert quickly) ---
echo "[1/7] Ensuring labels exist..."
gh label create "Ready"       --color "0E8A16" --description "Plan complete, ready for execution" $REPO_ARG 2>/dev/null || true
gh label create "Draft"       --color "CCCCCC" --description "Draft issue, not yet designed" $REPO_ARG 2>/dev/null || true
gh label create "smoke-test"  --color "FFA500" --description "Smoke test" $REPO_ARG 2>/dev/null || true
gh label create "priority:P0" --color "B60205" --description "Critical" $REPO_ARG 2>/dev/null || true
pass "Labels ensured"
echo ""

# --- Create the seed issue with a narrow, decomposable draft ---
# The draft is intentionally specific (explicit file paths, exact signatures)
# so the tactical-agent goes straight to Plan Mode without asking questions.
echo "[2/7] Creating seed feature issue..."
SEED_BODY=$(cat <<EOF
# Plan smoke test — ${TIMESTAMP}

Add two tiny utility modules under \`scripts/smoke-plan-${TIMESTAMP}/\`, each
with a documented signature. This is a synthetic test — no real
implementation is needed, the goal is just to exercise the /agents devise
pipeline end-to-end.

## Files to create

### \`scripts/smoke-plan-${TIMESTAMP}/add.sh\`

A bash function that sums two integers from positional args and echoes
the result.

\`\`\`bash
#!/usr/bin/env bash
# Usage: ./add.sh <a> <b>
# Echoes: a + b
set -euo pipefail
echo \$((\${1:-0} + \${2:-0}))
\`\`\`

### \`scripts/smoke-plan-${TIMESTAMP}/subtract.sh\`

A bash function that subtracts two integers from positional args.

\`\`\`bash
#!/usr/bin/env bash
# Usage: ./subtract.sh <a> <b>
# Echoes: a - b
set -euo pipefail
echo \$((\${1:-0} - \${2:-0}))
\`\`\`

## Acceptance Criteria

- Both files exist and are executable
- \`./add.sh 2 3\` echoes \`5\`
- \`./subtract.sh 5 3\` echoes \`2\`

## Notes

This issue is created by \`smoke-test-plan.sh\` and will be reverted via
\`/agents revert\` once the plan-pipeline assertions pass. Do not expect
the code to actually ship.
EOF
)

SEED_URL=$(gh issue create $REPO_ARG \
  --title "Smoke [plan pipeline] ${TIMESTAMP}" \
  --label "smoke-test" \
  --body "$SEED_BODY")
FEATURE=$(echo "$SEED_URL" | grep -oE '[0-9]+$')
echo "  Seed issue: #$FEATURE → $SEED_URL"

# Capture the creation body for comparison after revert. Fetch via GraphQL
# userContentEdits — which SHOULD include the initial creation as its first
# entry. If it doesn't, we fall back to the current body.
SEED_BODY_NOW=$(gh issue view $FEATURE $REPO_ARG --json body --jq '.body')
echo "  Seed body captured (${#SEED_BODY_NOW} chars)"
echo ""

# --- Trigger /agents devise ---
echo "[3/7] Triggering /agents devise sonnet low..."
PLAN_COMMENT_URL=$(gh issue comment $FEATURE $REPO_ARG --body "/agents devise sonnet low")
PLAN_COMMENT_ID=$(echo "$PLAN_COMMENT_URL" | grep -oE 'issuecomment-[0-9]+' | grep -oE '[0-9]+$' || echo "")
echo "  Plan comment posted (id: ${PLAN_COMMENT_ID:-unknown})"

if [[ "$WAIT" == false ]]; then
  echo ""
  echo "Skipping wait (--no-wait). Seed: $SEED_URL"
  exit 0
fi
echo ""

# --- Wait for tactical-agent terminal reaction ---
# Each `/agents` comment triggers every workflow; five skip via `if:`
# guards and one runs. GitHub occasionally emits more than one run for
# the same comment event, and `conclusion != "skipped"` can't filter
# them at pick-time because both are still `in_progress`. So we track
# the *comment reactions* the workflow itself posts (👀 → 👍/😕)
# instead of trying to pin a run ID. Reactions are tied to our specific
# comment, so parallel workflows on other issues don't cross-talk.
echo "[4/7] Waiting for tactical-agent terminal reaction..."
if [[ -z "${PLAN_COMMENT_ID:-}" ]]; then
  fail "cannot track tactical-agent — missing PLAN_COMMENT_ID"
  exit 1
fi
# `|| RC=$?` neutralizes `set -e` so non-zero returns don't abort the
# script before we can interpret them.
PLAN_RC=0
wait_for_reaction "$PLAN_COMMENT_ID" 600 "tactical-agent" || PLAN_RC=$?
case $PLAN_RC in
  0) pass "tactical-agent run completed successfully" ;;
  1) fail "tactical-agent run failed (😕 reaction on /agents devise comment)"; exit 1 ;;
  2) fail "tactical-agent run did not complete within 10 min"; exit 1 ;;
esac
echo ""

# --- Assert: reactions, body change, labels, tasks created ---
echo "[5/7] Asserting plan pipeline state..."

# Reactions on /agents devise comment
if [[ -n "$PLAN_COMMENT_ID" ]]; then
  REACTIONS=$(gh api "repos/$REPO/issues/comments/$PLAN_COMMENT_ID/reactions" --jq '[.[].content]' 2>/dev/null || echo "[]")
  if echo "$REACTIONS" | grep -q "eyes"; then pass "👀 reaction on /agents devise comment"; else warn "👀 reaction missing on /agents devise comment"; fi
  if echo "$REACTIONS" | grep -q "+1";   then pass "👍 reaction on /agents devise comment"; else warn "👍 reaction missing on /agents devise comment"; fi
fi

# Labels
LABELS=$(gh issue view $FEATURE $REPO_ARG --json labels --jq '[.labels[].name] | join(",")')
if echo "$LABELS" | grep -q "Ready"; then pass "Label 'Ready' applied to #$FEATURE"; else fail "Label 'Ready' missing"; fi

# Body changed
CURRENT_BODY=$(gh issue view $FEATURE $REPO_ARG --json body --jq '.body')
if [[ "$CURRENT_BODY" != "$SEED_BODY_NOW" ]]; then
  pass "Feature body updated by tactical-agent (${#CURRENT_BODY} chars vs ${#SEED_BODY_NOW} initial)"
else
  fail "Feature body unchanged — tactical-agent did not write the plan"
fi

# Extract task numbers from YAML block. Use a grep-only approach so we
# don't require yq on the runner (the workflow itself does use yq, but
# this smoke-test might run anywhere).
YAML_BLOCK=$(echo "$CURRENT_BODY" | awk '/^```yaml[[:space:]]*$/{flag=1;next}/^```[[:space:]]*$/{flag=0}flag')
TASK_NUMBERS=()
if [[ -n "$YAML_BLOCK" ]]; then
  # Match `tasks: [N, M, ...]` lines and extract every integer token.
  while IFS= read -r n; do
    [[ -n "$n" ]] && TASK_NUMBERS+=("$n")
  done < <(echo "$YAML_BLOCK" | grep -oE 'tasks:[[:space:]]*\[[^]]*\]' | grep -oE '[0-9]+' || true)
fi

if [[ ${#TASK_NUMBERS[@]:-0} -ge 1 ]]; then
  pass "Plan YAML contains ${#TASK_NUMBERS[@]} task number(s): ${TASK_NUMBERS[*]}"
else
  fail "Plan YAML has no task numbers — splitter output empty?"
fi

if [[ ${#TASK_NUMBERS[@]:-0} -eq 0 ]]; then
  echo "[!] No tasks to assert on — skipping per-task checks"
  TASK_NUMBERS=()
fi

# Each task has priority:P* label
for t in "${TASK_NUMBERS[@]:-}"; do
  [[ -z "$t" ]] && continue
  TLABELS=$(gh issue view $t $REPO_ARG --json labels --jq '[.labels[].name] | join(",")')
  if echo "$TLABELS" | grep -qE "priority:P"; then
    pass "Task #$t has priority label ($TLABELS)"
  else
    fail "Task #$t missing priority label"
  fi
done

# Issue type — soft assertion (depends on org config)
FEATURE_TYPE=$(gh issue view $FEATURE $REPO_ARG --json issueType --jq '.issueType.name // empty' 2>/dev/null || echo "")
if [[ "$FEATURE_TYPE" == "Feature" ]]; then
  pass "Issue type on #$FEATURE = Feature"
else
  warn "Issue type on #$FEATURE = '${FEATURE_TYPE:-none}' (Feature type may not be configured at the org)"
fi

for t in "${TASK_NUMBERS[@]:-}"; do
  [[ -z "$t" ]] && continue
  T_TYPE=$(gh issue view $t $REPO_ARG --json issueType --jq '.issueType.name // empty' 2>/dev/null || echo "")
  if [[ "$T_TYPE" == "Task" ]]; then
    pass "Issue type on #$t = Task"
  else
    warn "Issue type on #$t = '${T_TYPE:-none}' (Task type may not be configured)"
  fi
done

# Sub-issue relationships — soft assertion
SUB_ISSUES=$(gh api "repos/$REPO/issues/$FEATURE/sub_issues" --jq '[.[].number]' 2>/dev/null || echo "[]")
if [[ "$SUB_ISSUES" != "[]" ]]; then
  MATCHED=0
  for t in "${TASK_NUMBERS[@]:-}"; do
    [[ -z "$t" ]] && continue
    if echo "$SUB_ISSUES" | jq -e "index($t)" >/dev/null 2>&1; then
      MATCHED=$((MATCHED + 1))
    fi
  done
  if [[ $MATCHED -eq ${#TASK_NUMBERS[@]:-0} ]]; then
    pass "All ${#TASK_NUMBERS[@]} tasks linked as sub-issues of #$FEATURE"
  else
    warn "Only $MATCHED/${#TASK_NUMBERS[@]} tasks linked as sub-issues (API partial)"
  fi
else
  warn "No sub-issues found on #$FEATURE (sub-issues API may be unavailable)"
fi
echo ""

# --- Trigger /agents revert (unless --keep) ---
if [[ "$KEEP" == true ]]; then
  echo "[6/7] Skipping /agents revert (--keep). Test complete."
  echo ""
  echo "=== Summary ==="
  echo "  Fail:    $FAIL"
  echo "  Warn:    $WARN"
  [[ $FAIL -eq 0 ]] && echo "✅ Plan-pipeline assertions passed (kept state)." && exit 0 || { echo "❌ Plan-pipeline assertions failed."; exit 1; }
fi

echo "[6/7] Triggering /agents revert..."
REVERT_COMMENT_URL=$(gh issue comment $FEATURE $REPO_ARG --body "/agents revert")
REVERT_COMMENT_ID=$(echo "$REVERT_COMMENT_URL" | grep -oE 'issuecomment-[0-9]+' | grep -oE '[0-9]+$' || echo "")
echo "  Revert comment posted (id: ${REVERT_COMMENT_ID:-unknown})"

# Revert deletes its own triggering comment, so reactions aren't a
# viable signal. Watch the side effect instead: feature/draft labels
# stripped from the feature issue. Issue-scoped, so parallel reverts
# on other features don't cross-talk.
REVERT_RC=0
wait_for_feature_unplanned "$FEATURE" 120 || REVERT_RC=$?
case $REVERT_RC in
  0) pass "revert completed (labels stripped + comments deleted on #$FEATURE)" ;;
  2) fail "revert did not reach terminal state within 2 min" ;;
esac
echo ""

# --- Assert revert effects ---
echo "[7/7] Asserting revert state..."

# Tasks should be closed
for t in "${TASK_NUMBERS[@]:-}"; do
  [[ -z "$t" ]] && continue
  T_STATE=$(gh issue view $t $REPO_ARG --json state --jq '.state')
  if [[ "$T_STATE" == "CLOSED" ]]; then
    pass "Task #$t closed"
  else
    fail "Task #$t state=$T_STATE (expected CLOSED)"
  fi
done

# Feature labels stripped
FINAL_LABELS=$(gh issue view $FEATURE $REPO_ARG --json labels --jq '[.labels[].name] | join(",")')
if ! echo "$FINAL_LABELS" | grep -q "Ready"; then
  pass "Label 'Ready' removed from #$FEATURE"
else
  fail "Label 'Ready' still present (got: $FINAL_LABELS)"
fi
if ! echo "$FINAL_LABELS" | grep -q "draft"; then
  pass "Label 'draft' removed from #$FEATURE"
else
  fail "Label 'draft' still present"
fi

# All comments deleted (should be 0)
COMMENT_COUNT=$(gh api "repos/$REPO/issues/$FEATURE/comments" --jq '. | length' 2>/dev/null || echo "999")
if [[ "$COMMENT_COUNT" -eq 0 ]]; then
  pass "All comments deleted from #$FEATURE"
else
  fail "$COMMENT_COUNT comment(s) still present on #$FEATURE (expected 0)"
fi

# Body restored — soft assertion (depends on userContentEdits coverage)
POST_REVERT_BODY=$(gh issue view $FEATURE $REPO_ARG --json body --jq '.body')
if [[ "$POST_REVERT_BODY" == "$SEED_BODY_NOW" ]]; then
  pass "Feature body matches original seed after revert"
else
  warn "Feature body differs from seed after revert (expected if userContentEdits didn't track creation)"
fi

# Close the seed issue so it doesn't linger (revert keeps it open but
# unlabeled — we don't need it anymore).
gh issue close $FEATURE $REPO_ARG --comment "Smoke test complete — closing." 2>/dev/null || true
echo ""

# --- Summary ---
echo "=== Summary ==="
echo "  Fail:    $FAIL"
echo "  Warn:    $WARN"

if [[ $FAIL -eq 0 ]]; then
  if [[ $WARN -eq 0 ]]; then
    echo "✅ Plan pipeline smoke test passed with no warnings."
  else
    echo "✅ Plan pipeline smoke test passed with $WARN soft warning(s) (likely org-config gaps, not bugs)."
  fi
  exit 0
else
  echo "❌ Plan pipeline smoke test FAILED — $FAIL hard assertion(s) violated."
  exit 1
fi
