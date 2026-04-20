#!/usr/bin/env bash
# =============================================================================
# Smoke Test — Plan Pipeline Validator
# =============================================================================
#
# PURPOSE
# -------
# Exercises the parts of the workflow trio that scripts/smoke-test.sh skips:
#
#   1. /agents plan end-to-end (questions-free draft → plan written → task
#      issues created → labels/type/sub-issues applied).
#   2. GitHub native issue types (Feature on the draft, Task on each child).
#   3. Sub-issue relationships (children linked under the feature).
#   4. /agents revert (closes tasks, strips labels, deletes comments,
#      restores the body from userContentEdits history).
#   5. Per-comment reactions 👀 + 👍 (both /agents plan and /agents revert).
#
# COST
# ----
# Runs one plan-agent call at `sonnet low` reasoning to keep it cheap.
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
#   --no-wait       Create the seed issue and kickstart /agents plan,
#                   don't wait for completion.
#   --repo OWNER/REPO  Target repo (default: current repo from `gh`).
#   -h, --help      Show this help.
#
# ASSERTIONS (SOFT vs HARD)
# -------------------------
# Hard assertions (fail the test if violated):
#   - /agents plan run completes with success
#   - Feature issue receives `feature` + `draft` labels
#   - Issue body changes (plan written into it)
#   - At least 1 task issue created with `priority:P*` label
#   - /agents revert closes all task issues and strips labels
#
# Soft assertions (logged as warning if violated, test still passes):
#   - Issue type = Feature on the draft, Task on children
#     (requires org-level issue-type configuration)
#   - Sub-issue links exist (requires sub-issues API enabled)
#   - 👀 reaction on /agents plan comment (may miss if react.sh races)
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

# --- Ensure labels exist (plan agent creates priority:P* lazily but we
#     want them ready so we can assert quickly) ---
echo "[1/7] Ensuring labels exist..."
gh label create "feature"     --color "6F42C1" --description "Orchestration feature issue" $REPO_ARG 2>/dev/null || true
gh label create "draft"       --color "CCCCCC" --description "Plan drafted but not yet kickstarted" $REPO_ARG 2>/dev/null || true
gh label create "smoke-test"  --color "FFA500" --description "Smoke test" $REPO_ARG 2>/dev/null || true
gh label create "priority:P0" --color "B60205" --description "Critical" $REPO_ARG 2>/dev/null || true
pass "Labels ensured"
echo ""

# --- Create the seed issue with a narrow, decomposable draft ---
# The draft is intentionally specific (explicit file paths, exact signatures)
# so the plan-agent goes straight to Plan Mode without asking questions.
echo "[2/7] Creating seed feature issue..."
SEED_BODY=$(cat <<EOF
# Plan smoke test — ${TIMESTAMP}

Add two tiny utility modules under \`scripts/smoke-plan-${TIMESTAMP}/\`, each
with a documented signature. This is a synthetic test — no real
implementation is needed, the goal is just to exercise the /agents plan
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

# --- Trigger /agents plan ---
echo "[3/7] Triggering /agents plan sonnet low..."
PLAN_COMMENT_URL=$(gh issue comment $FEATURE $REPO_ARG --body "/agents plan sonnet low")
PLAN_COMMENT_ID=$(echo "$PLAN_COMMENT_URL" | grep -oE 'issuecomment-[0-9]+' | grep -oE '[0-9]+$' || echo "")
echo "  Plan comment posted (id: ${PLAN_COMMENT_ID:-unknown})"

if [[ "$WAIT" == false ]]; then
  echo ""
  echo "Skipping wait (--no-wait). Seed: $SEED_URL"
  exit 0
fi
echo ""

# --- Wait for plan-agent run to complete ---
echo "[4/7] Waiting for plan-agent run..."
# Find the run triggered by this comment. Event name + timing + event actor
# uniquely identify it.
PLAN_WAITED=0
PLAN_RUN_ID=""
# Every /agents comment fires ALL 6 workflows on this repo; most skip
# because their if: guard doesn't match. Filter out conclusion=skipped
# so we grab the one that's actually running /agents plan.
CUTOFF=$(date -u -v-2M '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d '-2 min' '+%Y-%m-%dT%H:%M:%SZ')
while [[ $PLAN_WAITED -lt 60 ]]; do
  PLAN_RUN_ID=$(gh run list --workflow="Claude Plan Agent" --limit 5 \
    --json databaseId,createdAt,conclusion \
    --jq "[.[] | select(.createdAt > \"$CUTOFF\" and .conclusion != \"skipped\")] | .[0].databaseId // empty" 2>/dev/null || echo "")
  [[ -n "$PLAN_RUN_ID" ]] && break
  sleep 5
  PLAN_WAITED=$((PLAN_WAITED + 5))
done

if [[ -z "$PLAN_RUN_ID" ]]; then
  fail "plan-agent run did not appear within 60s"
  exit 1
fi
echo "  Plan run: $PLAN_RUN_ID"

# Poll for completion (up to 10 min)
PLAN_WAITED=0
while [[ $PLAN_WAITED -lt 600 ]]; do
  STATUS=$(gh run view $PLAN_RUN_ID --json status,conclusion --jq '.status + "|" + (.conclusion // "")' 2>/dev/null || echo "")
  if [[ "$STATUS" == completed* ]]; then
    CONCLUSION=$(echo "$STATUS" | cut -d'|' -f2)
    if [[ "$CONCLUSION" == "success" ]]; then
      pass "plan-agent run completed successfully (${PLAN_WAITED}s)"
    else
      fail "plan-agent run completed with conclusion=$CONCLUSION"
      exit 1
    fi
    break
  fi
  sleep 15
  PLAN_WAITED=$((PLAN_WAITED + 15))
  echo "  ... $PLAN_WAITED/600s ($STATUS)"
done

if [[ $PLAN_WAITED -ge 600 ]]; then
  fail "plan-agent run did not complete within 10 min"
  exit 1
fi
echo ""

# --- Assert: reactions, body change, labels, tasks created ---
echo "[5/7] Asserting plan pipeline state..."

# Reactions on /agents plan comment
if [[ -n "$PLAN_COMMENT_ID" ]]; then
  REACTIONS=$(gh api "repos/$REPO/issues/comments/$PLAN_COMMENT_ID/reactions" --jq '[.[].content]' 2>/dev/null || echo "[]")
  if echo "$REACTIONS" | grep -q "eyes"; then pass "👀 reaction on /agents plan comment"; else warn "👀 reaction missing on /agents plan comment"; fi
  if echo "$REACTIONS" | grep -q "+1";   then pass "👍 reaction on /agents plan comment"; else warn "👍 reaction missing on /agents plan comment"; fi
fi

# Labels
LABELS=$(gh issue view $FEATURE $REPO_ARG --json labels --jq '[.labels[].name] | join(",")')
if echo "$LABELS" | grep -q "feature"; then pass "Label 'feature' applied to #$FEATURE"; else fail "Label 'feature' missing"; fi
if echo "$LABELS" | grep -q "draft";   then pass "Label 'draft' applied to #$FEATURE";   else fail "Label 'draft' missing"; fi

# Body changed
CURRENT_BODY=$(gh issue view $FEATURE $REPO_ARG --json body --jq '.body')
if [[ "$CURRENT_BODY" != "$SEED_BODY_NOW" ]]; then
  pass "Feature body updated by plan-agent (${#CURRENT_BODY} chars vs ${#SEED_BODY_NOW} initial)"
else
  fail "Feature body unchanged — plan-agent did not write the plan"
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

# Wait for revert run
sleep 5
REVERT_CUTOFF=$(date -u -v-1M '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d '-1 min' '+%Y-%m-%dT%H:%M:%SZ')
REVERT_RUN_ID=$(gh run list --workflow="Claude Agents — Revert" --limit 5 \
  --json databaseId,createdAt,conclusion \
  --jq "[.[] | select(.createdAt > \"$REVERT_CUTOFF\" and .conclusion != \"skipped\")] | .[0].databaseId // empty" 2>/dev/null || echo "")

if [[ -z "$REVERT_RUN_ID" ]]; then
  fail "revert run did not appear"
  exit 1
fi
echo "  Revert run: $REVERT_RUN_ID"

REVERT_WAITED=0
while [[ $REVERT_WAITED -lt 120 ]]; do
  STATUS=$(gh run view $REVERT_RUN_ID --json status,conclusion --jq '.status + "|" + (.conclusion // "")' 2>/dev/null || echo "")
  if [[ "$STATUS" == completed* ]]; then
    CONCLUSION=$(echo "$STATUS" | cut -d'|' -f2)
    if [[ "$CONCLUSION" == "success" ]]; then
      pass "revert run completed (${REVERT_WAITED}s)"
    else
      fail "revert run conclusion=$CONCLUSION"
    fi
    break
  fi
  sleep 10
  REVERT_WAITED=$((REVERT_WAITED + 10))
done
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
if ! echo "$FINAL_LABELS" | grep -q "feature"; then
  pass "Label 'feature' removed from #$FEATURE"
else
  fail "Label 'feature' still present (got: $FINAL_LABELS)"
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
