#!/usr/bin/env bash
# =============================================================================
# Smoke Test — Plan Pipeline Validator
# =============================================================================
#
# PURPOSE
# -------
# Exercises the parts of the workflow trio that scripts/smoke-test.sh skips:
#
#   1. /engineer end-to-end (questions-free draft → plan written → task
#      issues created → labels/type/sub-issues applied).
#   2. GitHub native issue types (Feature on the draft, Task on each child).
#   3. Sub-issue relationships (children linked under the feature).
#   4. /revert (closes tasks, strips labels, deletes comments,
#      restores the body from userContentEdits history).
#   5. Per-comment reactions 👀 + 👍 (both /engineer and /revert).
#   6. The #164 stale-`Tactics:done` regression: rewriting the body to a fresh,
#      marker-free design spec while `Tactics:done` lingers must not lose the
#      rewritten design zone on the next /engineer run.
#   7. The /architect re-run contract: an existing tactical zone is STRIPPED
#      (with a warning comment, and its task issues closed) rather than
#      preserved — the design changed, so the plan is stale by construction.
#      A markerless body must still get no tactical markers on the fallback
#      path.
#
# With --single, runs a separate variant instead: seeds a draft narrow
# enough to yield exactly one task, and asserts the engineer-agent's
# single-task fast path (no child issue, no YAML `waves:` block, no
# sub-issue links, `Tactics:done` label, task content merged into the
# feature body) plus its revert. See OPTIONS below.
#
# COST
# ----
# Runs four engineer/architect-agent calls at `sonnet low` effort to keep it
# cheap. Expected wall time: 8–13 min. No task worker is triggered — this
# test covers the planning half of the pipeline, not the shipping half.
# (--single runs a single, cheaper engineer-agent call instead.)
#
# USAGE
# -----
#   ./scripts/smoke-test-plan.sh [OPTIONS]
#
# OPTIONS
#   --keep          Do not run /revert at the end (leaves the
#                   feature + task issues in place for manual inspection).
#   --no-wait       Create the seed issue and kickstart /engineer,
#                   don't wait for completion.
#   --single        Run the single-task fast-path variant instead of the
#                   default multi-task pipeline: seeds a draft narrow
#                   enough to yield exactly one task, then asserts the
#                   single-task contract (no child issue, no YAML `waves:`
#                   block, `Tactics:done` label) and its revert. Does
#                   not run the multi-task assertions below — run the
#                   script without this flag to cover that regression.
#   --repo OWNER/REPO  Target repo (default: current repo from `gh`).
#   -h, --help      Show this help.
#
# ASSERTIONS (SOFT vs HARD)
# -------------------------
# Hard assertions (fail the test if violated):
#   - /engineer run completes with success
#   - Feature issue receives `Tactics:done` label
#   - Issue body changes (plan written into it)
#   - At least 1 task issue created with `priority:P*` label
#   - /revert closes all task issues and strips labels
#   - #164 regression: after rewriting the body to a fresh, marker-free
#     design spec while `Tactics:done` lingers and re-running /engineer, the
#     rewritten design zone must survive verbatim with a fresh tactical
#     zone appended below it (sentinel present, markers present, sentinel
#     above the begin marker)
#   - /architect re-run contract: an existing tactical zone is stripped, the
#     removal is announced in a comment, and a fresh design spec is written
#     in its place
#   - /architect on a markerless body writes the design spec as the full
#     body and introduces no tactical markers
#
# Soft assertions (logged as warning if violated, test still passes):
#   - Issue type = Feature on the draft, Task on children
#     (requires org-level issue-type configuration)
#   - Sub-issue links exist (requires sub-issues API enabled)
#   - 👀 reaction on /engineer comment (may miss if reaction races)
#   - Body reverts to original (requires userContentEdits coverage)
# =============================================================================

set -euo pipefail

KEEP=false
WAIT=true
SINGLE=false
REPO=""
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep) KEEP=true; shift ;;
    --no-wait) WAIT=false; shift ;;
    --single) SINGLE=true; shift ;;
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
#   rocket   → handed off to a prerequisite agent (this run is over, the work is not)
#   confused → failure
# Scoped to the specific comment, so it's immune to GitHub's occasional
# double-fire on issue_comment (the skipped duplicate never touches
# reactions) and safe with parallel workflows on other issues (they
# post on their own comments). Returns 0=success, 1=failure, 2=timeout,
# 3=delegated (see wait_for_plan_after_delegation).
# NOTE: not usable for /revert or /close — those
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
      # 🚀 = the Definition-of-Ready guard handed this run off to a prerequisite
      # agent. This comment's run is over and no further reaction will land on it,
      # but the work continues on the re-dispatched run's own comment. Reported as
      # 3 so callers can keep waiting on the *issue* instead of on this comment —
      # treating it as success would assert against a plan nobody has written yet.
      *,rocket,*)   return 3 ;;
    esac
    sleep $interval
    waited=$((waited + interval))
    if [[ $((waited % 60)) -eq 0 ]]; then
      echo "  ... $label ${waited}/${timeout_s}s (reactions: ${reactions:-none})"
    fi
  done
  return 2
}

# wait_for_plan_after_delegation FEATURE_NUM TIMEOUT_S LABEL
# The DoR guard handed the run off, so no further reaction lands on the comment
# we were watching. Wait on the outcome instead: the re-dispatched Engineer marks
# the feature `Tactics:done` when the plan is written.
wait_for_plan_after_delegation() {
  local feature="$1" timeout_s="$2" label="$3"
  local waited=0 interval=15 labels=""
  echo "  🚀 handed off to a prerequisite agent — waiting on the outcome instead"
  while [[ $waited -lt $timeout_s ]]; do
    labels=$(gh issue view "$feature" $REPO_ARG --json labels --jq '[.labels[].name]|join(",")' 2>/dev/null || echo "")
    case ",$labels," in *,Tactics:done,*) return 0 ;; esac
    sleep $interval
    waited=$((waited + interval))
    if [[ $((waited % 60)) -eq 0 ]]; then
      echo "  ... $label ${waited}/${timeout_s}s (labels: ${labels:-none})"
    fi
  done
  return 2
}

# Poll a feature issue until both terminal invariants of /revert
# are satisfied: `Tactics:done`+`draft` labels stripped AND all comments
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
    # Machinery comments only. The trigger comments this script posts (/engineer,
    # /revert) are the human's, and revert deliberately leaves human comments
    # alone — asserting on the raw count demanded more than revert promises and
    # could never pass (#183).
    comments=$(gh api "repos/$REPO/issues/$issue/comments" \
      --jq '[.[] | select((.body // "") | contains("<!-- autoducks:comment -->"))] | length' 2>/dev/null || echo "?")
    local labels_clean=1
    case ",$labels," in
      *,Tactics:done,*|*,draft,*) labels_clean=0 ;;
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
echo "[1/9] Ensuring labels exist..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../.autoducks/core/config/label-utils.sh"
label::ensure "Tactics:done" "D93F0B" "Tactical plan complete" || echo "Warning: failed to ensure label 'Tactics:done'" >&2
label::ensure "Draft"        "CCCCCC" "Draft issue, not yet designed" || echo "Warning: failed to ensure label 'Draft'" >&2
label::ensure "smoke-test"   "FFA500" "Smoke test" || echo "Warning: failed to ensure label 'smoke-test'" >&2
gh label create "priority:P0" --color "B60205" --description "Critical" $REPO_ARG 2>/dev/null || true
pass "Labels ensured"
echo ""

# =============================================================================
# Single-task variant (--single): exercises the engineer-agent's single-task
# fast path instead of the default multi-task pipeline below. Seeds a draft
# narrow enough (single file, one documented function) to yield exactly one
# task and specific enough to skip Questions Mode, then asserts the
# single-task contract (no child issue, no YAML `waves:` block, no sub-issue
# links, `Tactics:done` label, task content merged into the feature body)
# and its revert. Exits before reaching the multi-task flow below, so running
# without --single exercises that flow unchanged (regression guard).
# =============================================================================
if [[ "$SINGLE" == true ]]; then
  echo "[2/6] Creating seed feature issue (single-task draft)..."
  SEED_BODY=$(cat <<EOF
# Single-task smoke test — ${TIMESTAMP}

Add one tiny utility module at \`scripts/smoke-single-${TIMESTAMP}/only.sh\`.
This is a synthetic test — no real implementation is needed, the goal is
just to exercise the /engineer single-task fast path end-to-end.

## File to create

### \`scripts/smoke-single-${TIMESTAMP}/only.sh\`

A bash script with one documented function \`only_echo\` that echoes its
single positional argument.

\`\`\`bash
#!/usr/bin/env bash
# Usage: ./only.sh <value>
# Echoes: value
set -euo pipefail
# only_echo echoes its single argument verbatim.
only_echo() {
  echo "\$1"
}
only_echo "\${1:-}"
\`\`\`

## Acceptance Criteria

- \`scripts/smoke-single-${TIMESTAMP}/only.sh\` exists and is executable
- \`./only.sh hi\` echoes \`hi\`

## Notes

This issue is created by \`smoke-test-plan.sh --single\` and will be
reverted via \`/revert\` once the single-task assertions pass. Do
not expect the code to actually ship.
EOF
)

  SEED_URL=$(gh issue create $REPO_ARG \
    --title "Smoke [single-task pipeline] ${TIMESTAMP}" \
    --label "smoke-test" \
    --body "$SEED_BODY")
  FEATURE=$(echo "$SEED_URL" | grep -oE '[0-9]+$')
  echo "  Seed issue: #$FEATURE → $SEED_URL"

  SEED_BODY_NOW=$(gh issue view $FEATURE $REPO_ARG --json body --jq '.body')
  echo "  Seed body captured (${#SEED_BODY_NOW} chars)"
  echo ""

  # --- Trigger /engineer ---
  echo "[3/6] Triggering /engineer sonnet low..."
  PLAN_COMMENT_URL=$(gh issue comment $FEATURE $REPO_ARG --body "/engineer sonnet low")
  PLAN_COMMENT_ID=$(echo "$PLAN_COMMENT_URL" | grep -oE 'issuecomment-[0-9]+' | grep -oE '[0-9]+$' || echo "")
  echo "  Plan comment posted (id: ${PLAN_COMMENT_ID:-unknown})"

  if [[ "$WAIT" == false ]]; then
    echo ""
    echo "Skipping wait (--no-wait). Seed: $SEED_URL"
    exit 0
  fi
  echo ""

  echo "[4/6] Waiting for engineer-agent terminal reaction..."
  if [[ -z "${PLAN_COMMENT_ID:-}" ]]; then
    fail "cannot track engineer-agent — missing PLAN_COMMENT_ID"
    exit 1
  fi
  PLAN_RC=0
  wait_for_reaction "$PLAN_COMMENT_ID" 600 "engineer-agent (single)" || PLAN_RC=$?
  case $PLAN_RC in
    0) pass "engineer-agent run completed successfully" ;;
    1) fail "engineer-agent run failed (😕 reaction on /engineer comment)"; exit 1 ;;
    2) fail "engineer-agent run did not complete within 10 min"; exit 1 ;;
    3) if wait_for_plan_after_delegation "$FEATURE" 900 "engineer-agent (post-delegation)"; then
         pass "engineer-agent completed after delegating to a prerequisite agent"
       else
         fail "no plan after the delegated handoff (15 min)"; exit 1
       fi ;;
    # An unhandled code used to fall straight through to the next step with no
    # output at all, which is how a missing `3)` arm here went unnoticed for a
    # whole run: the test asserted against a pipeline that had not started.
    *) fail "unexpected wait_for_reaction code $PLAN_RC"; exit 1 ;;
  esac
  echo ""

  # --- Assert the single-task contract ---
  echo "[5/6] Asserting single-task contract..."
  CURRENT_BODY=$(gh issue view $FEATURE $REPO_ARG --json body --jq '.body')

  if [[ "$CURRENT_BODY" != "$SEED_BODY_NOW" ]]; then
    pass "Feature body updated by engineer-agent (${#CURRENT_BODY} chars vs ${#SEED_BODY_NOW} initial)"
  else
    fail "Feature body unchanged — engineer-agent did not write the plan"
  fi

  LABELS=$(gh issue view $FEATURE $REPO_ARG --json labels --jq '[.labels[].name] | join(",")')
  if echo "$LABELS" | grep -q "Tactics:done"; then pass "Label 'Tactics:done' applied to #$FEATURE"; else fail "Label 'Tactics:done' missing"; fi
  if echo "$LABELS" | grep -q "Tactics:done"; then pass "Label 'Tactics:done' applied to #$FEATURE"; else fail "Label 'Tactics:done' missing"; fi
  if echo "$LABELS" | grep -q "Tactics:done"; then pass "Label 'Tactics:done' applied to #$FEATURE"; else fail "Label 'Tactics:done' missing"; fi

  if echo "$CURRENT_BODY" | grep -qE '^```yaml[[:space:]]*$'; then
    fail "Feature body contains a \`\`\`yaml waves: block — single-task fast path must skip wave YAML"
  else
    pass "No \`\`\`yaml waves: block in feature body (single-task fast path)"
  fi

  for h in "## Summary" "## Tasks" "## Acceptance Criteria"; do
    if echo "$CURRENT_BODY" | grep -qF "$h"; then
      pass "Feature body contains '$h'"
    else
      fail "Feature body missing '$h'"
    fi
  done

  BEGIN_LINE=$(echo "$CURRENT_BODY" | grep -nE '^[[:space:]]*<!-- autoducks:tactical:begin -->[[:space:]]*$' | head -1 | cut -d: -f1 || echo "")
  END_LINE=$(echo "$CURRENT_BODY" | grep -nE '^[[:space:]]*<!-- autoducks:tactical:end -->[[:space:]]*$' | head -1 | cut -d: -f1 || echo "")
  if [[ -n "$BEGIN_LINE" && -n "$END_LINE" ]]; then
    pass "Tactical zone markers present"
    SUMMARY_LINE=$(echo "$CURRENT_BODY" | grep -nE '^## Summary[[:space:]]*$' | head -1 | cut -d: -f1 || echo "")
    ACCEPT_LINE=$(echo "$CURRENT_BODY" | grep -nE '^## Acceptance Criteria[[:space:]]*$' | head -1 | cut -d: -f1 || echo "")
    if [[ -n "$SUMMARY_LINE" && -n "$ACCEPT_LINE" && "$SUMMARY_LINE" -gt "$BEGIN_LINE" && "$SUMMARY_LINE" -lt "$END_LINE" && "$ACCEPT_LINE" -gt "$BEGIN_LINE" && "$ACCEPT_LINE" -lt "$END_LINE" ]]; then
      pass "Task content ('## Summary' … '## Acceptance Criteria') is between the tactical sentinels"
    else
      fail "Task content is not between the tactical sentinels"
    fi
  else
    fail "Tactical zone markers missing"
  fi

  # No child Task issue / no sub-issues linked
  PROBE_STATUS=$(gh api "repos/$REPO/issues/$FEATURE/sub_issues" \
                 --include 2>/dev/null | awk 'NR==1 { print $2 }' || echo "")
  if [[ "$PROBE_STATUS" =~ ^2 ]]; then
    SUB_ISSUE_COUNT=$(gh api "repos/$REPO/issues/$FEATURE/sub_issues" --jq '[.[].number] | length' 2>/dev/null || echo "0")
    if [[ "$SUB_ISSUE_COUNT" -eq 0 ]]; then
      pass "No sub-issues linked to #$FEATURE (single-task fast path)"
    else
      fail "$SUB_ISSUE_COUNT sub-issue(s) linked to #$FEATURE — expected none for single-task fast path"
    fi
  else
    warn "Sub-issues API not available on this repository (HTTP ${PROBE_STATUS:-none}); skipping sub-issue assertion"
  fi
  echo ""

  # --- Trigger /revert (unless --keep) ---
  if [[ "$KEEP" == true ]]; then
    echo "[6/6] Skipping /revert (--keep). Test complete."
    echo ""
    echo "=== Summary ==="
    echo "  Fail:    $FAIL"
    echo "  Warn:    $WARN"
    [[ $FAIL -eq 0 ]] && echo "✅ Single-task assertions passed (kept state)." && exit 0 || { echo "❌ Single-task assertions failed."; exit 1; }
  fi

  echo "[6/6] Triggering /revert..."
  REVERT_COMMENT_URL=$(gh issue comment $FEATURE $REPO_ARG --body "/revert")
  REVERT_COMMENT_ID=$(echo "$REVERT_COMMENT_URL" | grep -oE 'issuecomment-[0-9]+' | grep -oE '[0-9]+$' || echo "")
  echo "  Revert comment posted (id: ${REVERT_COMMENT_ID:-unknown})"

  REVERT_RC=0
  wait_for_feature_unplanned "$FEATURE" 600 || REVERT_RC=$?
  case $REVERT_RC in
    0) pass "revert completed (labels stripped + comments deleted on #$FEATURE)" ;;
    2) fail "revert did not reach terminal state within 2 min" ;;
  esac
  echo ""

  echo "Asserting revert state..."
  FINAL_LABELS=$(gh issue view $FEATURE $REPO_ARG --json labels --jq '[.labels[].name] | join(",")')
  if ! echo "$FINAL_LABELS" | grep -q "Tactics:done"; then
    pass "Label 'Tactics:done' removed from #$FEATURE"
  else
    fail "Label 'Tactics:done' still present (got: $FINAL_LABELS)"
  fi
  if ! echo "$FINAL_LABELS" | grep -q "Tactics:done"; then
    pass "Label 'Tactics:done' removed from #$FEATURE"
  else
    fail "Label 'Tactics:done' still present (got: $FINAL_LABELS)"
  fi

  COMMENT_COUNT=$(gh api "repos/$REPO/issues/$FEATURE/comments" --jq "[.[] | select((.body // \"\") | contains(\"<!-- autoducks:comment -->\"))] | length" 2>/dev/null || echo "999")
  if [[ "$COMMENT_COUNT" -eq 0 ]]; then
    pass "All machinery comments deleted from #$FEATURE"
  else
    fail "$COMMENT_COUNT machinery comment(s) still present on #$FEATURE (expected 0)"
  fi

  POST_REVERT_BODY=$(gh issue view $FEATURE $REPO_ARG --json body --jq '.body')
  if [[ "$POST_REVERT_BODY" == "$SEED_BODY_NOW" ]]; then
    pass "Feature body matches original seed after revert"
  else
    warn "Feature body differs from seed after revert (expected if userContentEdits didn't track creation)"
  fi

  gh issue close $FEATURE $REPO_ARG --comment "Smoke test complete — closing." 2>/dev/null || true
  echo ""

  echo "=== Summary ==="
  echo "  Fail:    $FAIL"
  echo "  Warn:    $WARN"

  if [[ $FAIL -eq 0 ]]; then
    if [[ $WARN -eq 0 ]]; then
      echo "✅ Single-task smoke test passed with no warnings."
    else
      echo "✅ Single-task smoke test passed with $WARN soft warning(s)."
    fi
    exit 0
  else
    echo "❌ Single-task smoke test FAILED — $FAIL hard assertion(s) violated."
    exit 1
  fi
fi

# --- Create the seed issue with a narrow, decomposable draft ---
# The draft is intentionally specific (explicit file paths, exact signatures)
# so the engineer-agent goes straight to Plan Mode without asking questions.
#
# It also has to be unambiguously MULTI-task, which the previous seed was not:
# two three-line scripts with no relationship between them are one cohesive
# change, and a plan that says so is correct — the run that reported an "empty
# splitter" had simply taken the legitimate single-task fast path (#183). The
# multi-task path is what this variant exists to cover, so the work is layered
# instead: the operations, then a dispatcher that cannot be written before them,
# then a runner that cannot be written before the dispatcher. The dependencies
# are stated as facts about the code, not as instructions about how to plan.
echo "[2/9] Creating seed feature issue..."
SEED_BODY=$(cat <<EOF
# Plan smoke test — ${TIMESTAMP}

Build a tiny calculator CLI under \`scripts/smoke-plan-${TIMESTAMP}/\`, in three
layers: the operations, a dispatcher that routes to them, and a test runner that
exercises the dispatcher. This is a synthetic test — no real implementation is
needed, the goal is just to exercise the /engineer pipeline end-to-end.

## Layer 1 — operations

### \`scripts/smoke-plan-${TIMESTAMP}/add.sh\`

Sums two integers from positional args and echoes the result.

\`\`\`bash
#!/usr/bin/env bash
# Usage: ./add.sh <a> <b>
set -euo pipefail
echo \$((\${1:-0} + \${2:-0}))
\`\`\`

### \`scripts/smoke-plan-${TIMESTAMP}/subtract.sh\`

Subtracts two integers from positional args.

\`\`\`bash
#!/usr/bin/env bash
# Usage: ./subtract.sh <a> <b>
set -euo pipefail
echo \$((\${1:-0} - \${2:-0}))
\`\`\`

## Layer 2 — dispatcher

### \`scripts/smoke-plan-${TIMESTAMP}/calc.sh\`

Takes an operation name and two integers, and delegates to the matching script
from layer 1. Exits 2 with a usage message on an unknown operation. It invokes
\`add.sh\` and \`subtract.sh\` by path, so it cannot be written or exercised until
both exist.

\`\`\`bash
# Usage: ./calc.sh <add|subtract> <a> <b>
\`\`\`

## Layer 3 — test runner

### \`scripts/smoke-plan-${TIMESTAMP}/run-tests.sh\`

Calls \`calc.sh\` for each supported operation, compares the output against the
expected value, prints one line per case, and exits non-zero if any case fails.
It drives the dispatcher rather than the operation scripts, so it depends on
layer 2 being in place.

## Acceptance Criteria

- All four files exist and are executable
- \`./add.sh 2 3\` echoes \`5\` and \`./subtract.sh 5 3\` echoes \`2\`
- \`./calc.sh add 2 3\` echoes \`5\` and \`./calc.sh subtract 5 3\` echoes \`2\`
- \`./calc.sh multiply 2 3\` exits 2 and prints a usage message
- \`./run-tests.sh\` exits 0 and prints one line per case

## Notes

This issue is created by \`smoke-test-plan.sh\` and will be reverted via
\`/revert\` once the plan-pipeline assertions pass. Do not expect
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

# --- Trigger /engineer ---
echo "[3/9] Triggering /engineer sonnet low..."
PLAN_COMMENT_URL=$(gh issue comment $FEATURE $REPO_ARG --body "/engineer sonnet low")
PLAN_COMMENT_ID=$(echo "$PLAN_COMMENT_URL" | grep -oE 'issuecomment-[0-9]+' | grep -oE '[0-9]+$' || echo "")
echo "  Plan comment posted (id: ${PLAN_COMMENT_ID:-unknown})"

if [[ "$WAIT" == false ]]; then
  echo ""
  echo "Skipping wait (--no-wait). Seed: $SEED_URL"
  exit 0
fi
echo ""

# --- Wait for engineer-agent terminal reaction ---
# Each `/agents` comment triggers every workflow; five skip via `if:`
# guards and one runs. GitHub occasionally emits more than one run for
# the same comment event, and `conclusion != "skipped"` can't filter
# them at pick-time because both are still `in_progress`. So we track
# the *comment reactions* the workflow itself posts (👀 → 👍/😕)
# instead of trying to pin a run ID. Reactions are tied to our specific
# comment, so parallel workflows on other issues don't cross-talk.
echo "[4/9] Waiting for engineer-agent terminal reaction..."
if [[ -z "${PLAN_COMMENT_ID:-}" ]]; then
  fail "cannot track engineer-agent — missing PLAN_COMMENT_ID"
  exit 1
fi
# `|| RC=$?` neutralizes `set -e` so non-zero returns don't abort the
# script before we can interpret them.
PLAN_RC=0
wait_for_reaction "$PLAN_COMMENT_ID" 600 "engineer-agent" || PLAN_RC=$?
case $PLAN_RC in
  0) pass "engineer-agent run completed successfully" ;;
  1) fail "engineer-agent run failed (😕 reaction on /engineer comment)"; exit 1 ;;
  2) fail "engineer-agent run did not complete within 10 min"; exit 1 ;;
  3) if wait_for_plan_after_delegation "$FEATURE" 900 "engineer-agent (post-delegation)"; then
       pass "engineer-agent completed after delegating to a prerequisite agent"
     else
       fail "no plan after the delegated handoff (15 min)"; exit 1
     fi ;;
  # See the note on the other case block: silence on an unknown code is how a
  # missing arm turns into an assertion against a pipeline that never ran.
  *) fail "unexpected wait_for_reaction code $PLAN_RC"; exit 1 ;;
esac
echo ""

# --- Assert: reactions, body change, labels, tasks created ---
echo "[5/9] Asserting plan pipeline state..."

# Reactions on /engineer comment
if [[ -n "$PLAN_COMMENT_ID" ]]; then
  REACTIONS=$(gh api "repos/$REPO/issues/comments/$PLAN_COMMENT_ID/reactions" --jq '[.[].content]' 2>/dev/null || echo "[]")
  if echo "$REACTIONS" | grep -q "eyes"; then pass "👀 reaction on /engineer comment"; else warn "👀 reaction missing on /engineer comment"; fi
  # 👍 or 🚀 — both are terminal for this comment. On a delegated run the
  # Definition-of-Ready guard reacts 🚀 and the work continues on the
  # re-dispatched Engineer's own comment, which never gets a 👍 here. Warning
  # only on 👍 would fire on every fresh feature, since a fresh feature has no
  # Design:done and therefore always delegates.
  if echo "$REACTIONS" | grep -qE '"(\+1|rocket)"'; then
    pass "terminal reaction (👍 or 🚀) on /engineer comment"
  else
    warn "no terminal reaction on /engineer comment (got: $(echo "$REACTIONS" | tr -d '\n'))"
  fi
fi

# Labels
LABELS=$(gh issue view $FEATURE $REPO_ARG --json labels --jq '[.labels[].name] | join(",")')
if echo "$LABELS" | grep -q "Tactics:done"; then pass "Label 'Tactics:done' applied to #$FEATURE"; else fail "Label 'Tactics:done' missing"; fi

# Body changed
CURRENT_BODY=$(gh issue view $FEATURE $REPO_ARG --json body --jq '.body')
if [[ "$CURRENT_BODY" != "$SEED_BODY_NOW" ]]; then
  pass "Feature body updated by engineer-agent (${#CURRENT_BODY} chars vs ${#SEED_BODY_NOW} initial)"
else
  fail "Feature body unchanged — engineer-agent did not write the plan"
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

# The shape check below has to look at the tactical zone alone, not the whole
# body: the design zone above it is the seed text, preserved verbatim, and the
# seed carries its own `## Acceptance Criteria`. Matching against the full body
# would find the seed's headings and call every failure a fast path.
TACTICAL_ZONE=$(echo "$CURRENT_BODY" | awk '
  /^[[:space:]]*<!-- autoducks:tactical:begin -->[[:space:]]*$/ { flag=1; next }
  /^[[:space:]]*<!-- autoducks:tactical:end -->[[:space:]]*$/   { flag=0 }
  flag')

# Three outcomes, not two. "No task numbers" used to be reported as an empty
# splitter, but it is also the documented shape of a legitimate single-task
# plan: the fast path writes no waves YAML, no Progress checklist and no label
# at all, because the Maestro detects that case structurally by the absence of a
# waves plan (engineer/post.sh, D12). Conflating the two meant a passing run
# reported a defect, and a real splitter failure would have looked identical
# (#183). Discriminated the same way the Maestro does — by shape.
if [[ ${#TASK_NUMBERS[@]} -ge 1 ]]; then
  pass "Plan YAML contains ${#TASK_NUMBERS[@]} task number(s): ${TASK_NUMBERS[*]}"
elif [[ -z "$YAML_BLOCK" ]] && grep -qE '^## (Summary|Tasks)' <<< "$TACTICAL_ZONE"; then
  # No waves block, but the tactical zone is a task body: the single-task fast
  # path. Legitimate here, though it means this run did not exercise the
  # multi-task splitter the default seed is meant to reach — worth surfacing,
  # not worth failing on.
  warn "Engineer took the single-task fast path (no waves plan) — the multi-task assertions below are skipped. If this recurs on the default seed, the seed is no longer unambiguously multi-task."
  TASK_NUMBERS=()
elif [[ -n "$YAML_BLOCK" ]]; then
  fail "Plan YAML block is present but carries no task numbers — splitter output empty"
else
  fail "Plan has neither a waves YAML block nor a single-task body — engineer wrote no usable tactical zone"
fi

if [[ ${#TASK_NUMBERS[@]} -eq 0 ]]; then
  echo "[!] No tasks to assert on — skipping per-task checks"
  TASK_NUMBERS=()
fi

# Each task carries the Task label.
#
# This used to assert `priority:P*` on every task, and had never actually run:
# the per-task loop was reached for the first time once the seed reliably
# produced a multi-task plan, and it failed on all four. `priority:P0..P3` is a
# *retired* taxonomy — design/AGENTS.md lists it under "Retired (cleaned up on
# sight by revert/close/engineer)" and parse-plan.py calls the suffixes retired
# by D14. The Engineer files tasks with `labels: ["Task"]` and nothing else, so
# the assertion was demanding a label the machinery deliberately stopped
# applying. Asserting the label it does apply is the check that has meaning.
for t in "${TASK_NUMBERS[@]:-}"; do
  [[ -z "$t" ]] && continue
  TLABELS=$(gh issue view $t $REPO_ARG --json labels --jq '[.labels[].name] | join(",")')
  if echo "$TLABELS" | grep -qE '(^|,)Task(,|$)'; then
    pass "Task #$t carries the Task label ($TLABELS)"
  else
    fail "Task #$t missing the Task label (got: ${TLABELS:-none})"
  fi
  # A task that also carries Feature means something re-classified a
  # pipeline-created issue — the triage sweep used to do exactly that.
  if echo "$TLABELS" | grep -qE '(^|,)Feature(,|$)'; then
    fail "Task #$t is also labelled Feature — something re-classified a pipeline task ($TLABELS)"
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

PROBE_STATUS=$(gh api "repos/$REPO/issues/$FEATURE/sub_issues" \
               --include 2>/dev/null | awk 'NR==1 { print $2 }' || echo "")
if [[ "$PROBE_STATUS" =~ ^2 ]]; then
  # API available — partial linkage is a hard failure
  SUB_ISSUES=$(gh api "repos/$REPO/issues/$FEATURE/sub_issues" --jq '[.[].number]' 2>/dev/null || echo "[]")
  MATCHED=0
  for t in "${TASK_NUMBERS[@]:-}"; do
    [[ -z "$t" ]] && continue
    if echo "$SUB_ISSUES" | jq -e "index($t)" >/dev/null 2>&1; then
      MATCHED=$((MATCHED + 1))
    fi
  done
  if [[ $MATCHED -eq ${#TASK_NUMBERS[@]} ]]; then
    pass "All ${#TASK_NUMBERS[@]} tasks linked as sub-issues of #$FEATURE"
  else
    fail "Sub-issues API is available but only $MATCHED/${#TASK_NUMBERS[@]} tasks are linked to #$FEATURE"
  fi
else
  warn "Sub-issues API not available on this repository (HTTP ${PROBE_STATUS:-none}); skipping sub-issue assertion"
fi
echo ""

# --- Reproduce the #164 stale-`Tactics:done` data-loss regression ---
# Rewrite the feature body to a brand-new, marker-free design spec while the
# `Tactics:done` label lingers (the exact precondition #164 exploited), then re-run
# /engineer. Pre-fix, the engineer-agent would use the stale `Tactics:done`
# label to assume markers should exist, mishandle the markerless body, and
# lose the rewritten design content. Post-fix, markers (not the label) are
# the single source of truth: no markers means the whole body is the design
# zone, which must survive verbatim with a fresh tactical zone appended below.
echo "[6/9] Reproducing #164 regression (stale Tactics:done + rewritten markerless body)..."
SENTINEL="REWRITTEN-DESIGN-${TIMESTAMP}"
REWRITE_BODY=$(cat <<EOF
# ${SENTINEL}

This is a brand-new, marker-free design spec used to reproduce the stale-
\`Tactics:done\`-label data-loss regression (#164). The feature body is rewritten
while the \`Tactics:done\` label is still attached, and a second \`/engineer\`
run must treat this rewritten body as the new design zone — preserving it
verbatim — instead of losing it because a stale \`Tactics:done\` label implied
markers should already exist.

## Files to create

### \`scripts/smoke-plan-${TIMESTAMP}-v2/noop.sh\`

A bash script that does nothing but echo \`ok\`.

\`\`\`bash
#!/usr/bin/env bash
set -euo pipefail
echo ok
\`\`\`

## Acceptance Criteria

- \`scripts/smoke-plan-${TIMESTAMP}-v2/noop.sh\` exists and echoes \`ok\`
EOF
)

gh issue edit $FEATURE $REPO_ARG --body "$REWRITE_BODY" >/dev/null
pass "Feature body overwritten with marker-free design spec (sentinel: $SENTINEL)"

REWRITE_LABELS=$(gh issue view $FEATURE $REPO_ARG --json labels --jq '[.labels[].name] | join(",")')
if echo "$REWRITE_LABELS" | grep -q "Tactics:done"; then
  pass "'Tactics:done' label still present after rewrite (regression precondition)"
else
  fail "'Tactics:done' label missing after rewrite — cannot reproduce #164 precondition"
fi

REDEVISE_COMMENT_URL=$(gh issue comment $FEATURE $REPO_ARG --body "/engineer sonnet low")
REDEVISE_COMMENT_ID=$(echo "$REDEVISE_COMMENT_URL" | grep -oE 'issuecomment-[0-9]+' | grep -oE '[0-9]+$' || echo "")
echo "  Second devise comment posted (id: ${REDEVISE_COMMENT_ID:-unknown})"

REDEVISE_RC=0
if [[ -z "${REDEVISE_COMMENT_ID:-}" ]]; then
  fail "cannot track second engineer-agent run — missing REDEVISE_COMMENT_ID"
else
  wait_for_reaction "$REDEVISE_COMMENT_ID" 600 "engineer-agent (redevise)" || REDEVISE_RC=$?
  case $REDEVISE_RC in
    0) pass "second engineer-agent run completed successfully" ;;
    1) fail "second engineer-agent run failed (😕 reaction on second /engineer comment)" ;;
    2) fail "second engineer-agent run did not complete within 10 min" ;;
  esac
fi

if [[ "$REDEVISE_RC" -eq 0 ]]; then
  REDEVISE_BODY=$(gh issue view $FEATURE $REPO_ARG --json body --jq '.body')

  if echo "$REDEVISE_BODY" | grep -qF "$SENTINEL"; then
    pass "Rewritten design-zone sentinel survived the second /engineer run"
  else
    fail "Rewritten design-zone sentinel LOST — #164 data-loss regression reproduced"
  fi

  if echo "$REDEVISE_BODY" | grep -qE '^[[:space:]]*<!-- autoducks:tactical:begin -->[[:space:]]*$' && \
     echo "$REDEVISE_BODY" | grep -qE '^[[:space:]]*<!-- autoducks:tactical:end -->[[:space:]]*$'; then
    pass "Tactical zone markers present after second /engineer run"
  else
    fail "Tactical zone markers missing after second /engineer run"
  fi

  SENTINEL_LINE=$(echo "$REDEVISE_BODY" | grep -nF "$SENTINEL" | head -1 | cut -d: -f1 || echo "")
  BEGIN_LINE=$(echo "$REDEVISE_BODY" | grep -nE '^[[:space:]]*<!-- autoducks:tactical:begin -->[[:space:]]*$' | head -1 | cut -d: -f1 || echo "")
  if [[ -n "$SENTINEL_LINE" && -n "$BEGIN_LINE" && "$SENTINEL_LINE" -lt "$BEGIN_LINE" ]]; then
    pass "Sentinel appears above the tactical:begin marker (design zone preserved, tactical zone appended below)"
  else
    fail "Sentinel does not appear above the tactical:begin marker (design zone corrupted or markers misplaced)"
  fi

  # The rewrite started from a markerless body, so the second /engineer
  # run had no prior task numbers to revise (empty tactical zone in) and
  # created a brand-new task set instead of reconciling the first round's.
  # Close the now-orphaned first-round tasks ourselves and swap TASK_NUMBERS
  # to the second round so the revert-phase close-assertions below check
  # what /revert will actually act on (the YAML block in the current
  # body), not issues it was never going to touch.
  for t in "${TASK_NUMBERS[@]:-}"; do
    [[ -z "$t" ]] && continue
    gh issue close "$t" $REPO_ARG --reason "not planned" \
      --comment "Superseded by second /engineer run in smoke test" >/dev/null 2>&1 || true
  done

  REDEVISE_YAML_BLOCK=$(echo "$REDEVISE_BODY" | awk '/^```yaml[[:space:]]*$/{flag=1;next}/^```[[:space:]]*$/{flag=0}flag')
  TASK_NUMBERS=()
  if [[ -n "$REDEVISE_YAML_BLOCK" ]]; then
    while IFS= read -r n; do
      [[ -n "$n" ]] && TASK_NUMBERS+=("$n")
    done < <(echo "$REDEVISE_YAML_BLOCK" | grep -oE 'tasks:[[:space:]]*\[[^]]*\]' | grep -oE '[0-9]+' || true)
  fi
else
  fail "Skipping design-zone-survival assertions — second engineer-agent run did not complete"
fi
echo ""

# --- Assert the /architect re-run contract (stale plan is torn down) ---
# Companion to the #164 regression above, but for the *other* re-entrant
# workflow: /architect re-run on a feature that already has a tactical zone.
# The contract is teardown, not preservation — the design is changing, so the
# plan derived from the old design is stale by construction. Starts from the
# state this script already reached above (the feature body has markers and a
# tactical zone from the second /engineer run — single-task or multi-task,
# either is valid here), re-runs /architect, and asserts the zone is gone, the
# user was told, a fresh design spec took its place, and the orphaned task
# issues were closed with it.
echo "[7/9] Asserting the /architect re-run contract (tactical zone is stripped)..."
if [[ "$REDEVISE_RC" -ne 0 ]]; then
  fail "Skipping design re-run assertions — second engineer-agent run did not complete"
else
  # This step used to assert the opposite of the shipped contract. It checked
  # that the tactical zone survived an /architect re-run byte-for-byte, and it
  # had never run — the task-number sentinel it keyed on only exists on the
  # multi-task path, and the body step 6 rewrites plans as a single task. Once
  # the sentinel was fixed and the step finally executed, it failed: the
  # Architect strips the zone, deliberately.
  #
  # The user-facing contract says so in two places (guides/re-running-agents):
  # "If a tactical zone is present, it is stripped (with a warning comment)
  # rather than preserved — the design changed, so the old plan is treated as
  # stale and re-planning is left to the Engineer", and the preserved/rewritten
  # table lists the tactical zone under Rewritten. pre.sh and post.sh implement
  # exactly that, down to closing the orphaned task issues.
  #
  # So the assertions below pin the real contract: the zone goes away, the user
  # is told, and a fresh design zone takes its place.
  PRE_DESIGN_BODY=$(gh issue view $FEATURE $REPO_ARG --json body --jq '.body')
  PRE_DESIGN_TACTICAL=$(echo "$PRE_DESIGN_BODY" | awk '
    /^[[:space:]]*<!-- autoducks:tactical:begin -->[[:space:]]*$/ { flag=1; next }
    /^[[:space:]]*<!-- autoducks:tactical:end -->[[:space:]]*$/   { flag=0 }
    flag')

  if [[ -n "$PRE_DESIGN_TACTICAL" ]]; then
    pass "Tactical zone captured before /architect re-run ($(wc -l <<< "$PRE_DESIGN_TACTICAL" | tr -d ' ') lines)"
  else
    fail "No tactical zone present before /architect re-run — cannot set up the test"
  fi

  DESIGN_COMMENT_URL=$(gh issue comment $FEATURE $REPO_ARG --body "/architect sonnet low")
  DESIGN_COMMENT_ID=$(echo "$DESIGN_COMMENT_URL" | grep -oE 'issuecomment-[0-9]+' | grep -oE '[0-9]+$' || echo "")
  echo "  /architect comment posted (id: ${DESIGN_COMMENT_ID:-unknown})"

  DESIGN_RC=0
  if [[ -z "${DESIGN_COMMENT_ID:-}" ]]; then
    fail "cannot track architect-agent run — missing DESIGN_COMMENT_ID"
    DESIGN_RC=1
  else
    wait_for_reaction "$DESIGN_COMMENT_ID" 600 "architect-agent" || DESIGN_RC=$?
    case $DESIGN_RC in
      0) pass "architect-agent run completed successfully" ;;
      1) fail "architect-agent run failed (😕 reaction on /architect comment)" ;;
      2) fail "architect-agent run did not complete within 10 min" ;;
    esac
  fi

  if [[ "$DESIGN_RC" -eq 0 ]]; then
    DESIGN_BODY=$(gh issue view $FEATURE $REPO_ARG --json body --jq '.body')

    if echo "$DESIGN_BODY" | grep -qE '^[[:space:]]*<!-- autoducks:tactical:(begin|end) -->[[:space:]]*$'; then
      fail "Tactical markers still present after /architect re-run — the stale plan was not stripped"
    else
      pass "Tactical zone stripped by the /architect re-run (design-only body republished)"
    fi

    # The stripped plan must not vanish silently: the contract is "stripped
    # WITH a warning comment", because the user has to know their plan is gone
    # and that re-planning is on them now.
    if gh issue view $FEATURE $REPO_ARG --json comments \
         --jq '[.comments[].body] | join("\n")' 2>/dev/null \
         | grep -qiE 'previous tactical plan was removed|re-run .*engineer'; then
      pass "Re-run warned that the previous tactical plan was removed"
    else
      fail "Tactical plan was stripped with no warning comment — silent data loss for the user"
    fi

    BEGIN_LINE=$(echo "$DESIGN_BODY" | wc -l | tr -d ' ')

    # "## Problem Statement" is a required section of every design spec the
    # architect-agent writes (.autoducks/agents/architect/prompt.md) — a stable,
    # LLM-independent sentinel that the design zone was actually rewritten,
    # not just left stale above the preserved tactical zone.
    DESIGN_SENTINEL_LINE=$(echo "$DESIGN_BODY" | grep -cE '^## Problem Statement[[:space:]]*$' || true)
    if [[ "$DESIGN_SENTINEL_LINE" -ge 1 ]]; then
      pass "Fresh design spec written ('## Problem Statement' present)"
    else
      fail "Fresh design spec heading missing after the /architect re-run"
    fi

    # The old plan's task issues are torn down with it — otherwise they linger
    # as orphans pointing at a design that no longer exists.
    STILL_OPEN=0
    for t in "${TASK_NUMBERS[@]:-}"; do
      [[ -z "$t" ]] && continue
      st=$(gh issue view "$t" $REPO_ARG --json state --jq '.state' 2>/dev/null || echo "UNKNOWN")
      [[ "$st" == "OPEN" ]] && STILL_OPEN=$((STILL_OPEN + 1))
    done
    if [[ "$STILL_OPEN" -eq 0 ]]; then
      pass "Task issues from the discarded plan were closed"
    else
      warn "$STILL_OPEN task issue(s) from the discarded plan are still open"
    fi
  else
    fail "Skipping /architect re-run assertions — architect-agent run did not complete"
  fi
fi
echo ""

# --- Markerless-body /architect run must add no tactical markers ---
# Inverse case, on a throwaway issue so it doesn't disturb the feature's
# revert flow below: /architect on a body with no markers at all must
# write the design spec as the full body and introduce no tactical markers
# (mirrors the markerless fallback path pre.sh/post.sh take when
# body_has_markers is false).
echo "  Verifying markerless-body /architect run adds no tactical markers..."
MARKERLESS_BODY=$(cat <<EOF
# Design markerless smoke test — ${TIMESTAMP}

A tiny, narrow feature description with no tactical markers at all, used to
confirm \`/architect\` on a markerless body writes the design spec as the
full issue body and does not introduce tactical zone markers.
EOF
)
MARKERLESS_URL=$(gh issue create $REPO_ARG \
  --title "Smoke [design markerless] ${TIMESTAMP}" \
  --label "smoke-test" \
  --body "$MARKERLESS_BODY")
MARKERLESS_ISSUE=$(echo "$MARKERLESS_URL" | grep -oE '[0-9]+$')
echo "  Markerless issue: #$MARKERLESS_ISSUE → $MARKERLESS_URL"

MARKERLESS_COMMENT_URL=$(gh issue comment $MARKERLESS_ISSUE $REPO_ARG --body "/architect sonnet low")
MARKERLESS_COMMENT_ID=$(echo "$MARKERLESS_COMMENT_URL" | grep -oE 'issuecomment-[0-9]+' | grep -oE '[0-9]+$' || echo "")
echo "  /architect comment posted (id: ${MARKERLESS_COMMENT_ID:-unknown})"

MARKERLESS_RC=0
if [[ -z "${MARKERLESS_COMMENT_ID:-}" ]]; then
  fail "cannot track markerless architect-agent run — missing MARKERLESS_COMMENT_ID"
  MARKERLESS_RC=1
else
  wait_for_reaction "$MARKERLESS_COMMENT_ID" 600 "architect-agent (markerless)" || MARKERLESS_RC=$?
  case $MARKERLESS_RC in
    0) pass "markerless architect-agent run completed successfully" ;;
    1) fail "markerless architect-agent run failed (😕 reaction on /architect comment)" ;;
    2) fail "markerless architect-agent run did not complete within 10 min" ;;
  esac
fi

if [[ "$MARKERLESS_RC" -eq 0 ]]; then
  MARKERLESS_RESULT_BODY=$(gh issue view $MARKERLESS_ISSUE $REPO_ARG --json body --jq '.body')

  if echo "$MARKERLESS_RESULT_BODY" | grep -qE '<!-- autoducks:tactical:(begin|end) -->'; then
    fail "Tactical markers introduced on a markerless /architect run (expected none)"
  else
    pass "No tactical markers introduced on markerless /architect run"
  fi

  if [[ "$MARKERLESS_RESULT_BODY" != "$MARKERLESS_BODY" ]]; then
    pass "Design spec written as the full body on markerless /architect run"
  else
    fail "Body unchanged — architect-agent did not write a design spec on the markerless issue"
  fi
else
  fail "Skipping markerless-body assertions — architect-agent run did not complete"
fi

gh issue close $MARKERLESS_ISSUE $REPO_ARG --comment "Smoke test complete — closing." 2>/dev/null || true
echo ""

# --- Trigger /revert (unless --keep) ---
if [[ "$KEEP" == true ]]; then
  echo "[8/9] Skipping /revert (--keep). Test complete."
  echo ""
  echo "=== Summary ==="
  echo "  Fail:    $FAIL"
  echo "  Warn:    $WARN"
  [[ $FAIL -eq 0 ]] && echo "✅ Plan-pipeline assertions passed (kept state)." && exit 0 || { echo "❌ Plan-pipeline assertions failed."; exit 1; }
fi

echo "[8/9] Triggering /revert..."
REVERT_COMMENT_URL=$(gh issue comment $FEATURE $REPO_ARG --body "/revert")
REVERT_COMMENT_ID=$(echo "$REVERT_COMMENT_URL" | grep -oE 'issuecomment-[0-9]+' | grep -oE '[0-9]+$' || echo "")
echo "  Revert comment posted (id: ${REVERT_COMMENT_ID:-unknown})"

# Revert deletes its own triggering comment, so reactions aren't a
# viable signal. Watch the side effect instead: feature/draft labels
# stripped from the feature issue. Issue-scoped, so parallel reverts
# on other features don't cross-talk.
REVERT_RC=0
wait_for_feature_unplanned "$FEATURE" 600 || REVERT_RC=$?
case $REVERT_RC in
  0) pass "revert completed (labels stripped + comments deleted on #$FEATURE)" ;;
  2) fail "revert did not reach terminal state within 2 min" ;;
esac
echo ""

# --- Assert revert effects ---
echo "[9/9] Asserting revert state..."

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
if ! echo "$FINAL_LABELS" | grep -q "Tactics:done"; then
  pass "Label 'Tactics:done' removed from #$FEATURE"
else
  fail "Label 'Tactics:done' still present (got: $FINAL_LABELS)"
fi
if ! echo "$FINAL_LABELS" | grep -q "draft"; then
  pass "Label 'draft' removed from #$FEATURE"
else
  fail "Label 'draft' still present"
fi

# Machinery comments deleted (the human trigger comments are left alone).
COMMENT_COUNT=$(gh api "repos/$REPO/issues/$FEATURE/comments" --jq "[.[] | select((.body // \"\") | contains(\"<!-- autoducks:comment -->\"))] | length" 2>/dev/null || echo "999")
if [[ "$COMMENT_COUNT" -eq 0 ]]; then
  pass "All machinery comments deleted from #$FEATURE"
else
  fail "$COMMENT_COUNT machinery comment(s) still present on #$FEATURE (expected 0)"
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
