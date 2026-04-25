#!/usr/bin/env bash
# =============================================================================
# Smoke Test — Agentic Workflow Validator
# =============================================================================
#
# PURPOSE
# -------
# Generic smoke test for the autoducks-wave / autoducks-execute / autoducks-fix
# workflow trio. Creates a feature issue with 3 trivial tasks in 2 waves, kickstarts the
# orchestrator, and optionally waits for completion.
#
# USAGE
# -----
#   ./smoke-test.sh [OPTIONS]
#
# OPTIONS
#   --cleanup       Close issues/PR and delete branches after test completes
#   --no-wait       Create issues and kickstart, don't wait for completion
#   --repo OWNER/REPO  Target repo (default: current repo from `gh`)
#   -h, --help      Show this help
#
# REQUIREMENTS
# ------------
# - gh CLI authenticated with repo access
# - autoducks-wave.yml, autoducks-execute.yml, autoducks-fix.yml workflows installed
# - `Feature`, `Ready`, and `smoke-test` labels (created automatically if missing)
# - ANTHROPIC_API_KEY secret configured
# - Claude Code GitHub App installed on the repo
# - Actions permission "Read and write" enabled
#
# VALIDATION SCENARIOS
# --------------------
# Wave 1 (Foundation):
#   Task 1: Create a new file
#
# Wave 2 (Parallel, both depend on Task 1):
#   Task 2: Append to the existing file
#   Task 3: Create a second new file
#
# This validates:
# - Wave orchestrator kickstart via /agents execute comment
# - Task worker triggered by wave dispatch
# - Branch creation under feature/<N>-<slug>/task/<T>-<slug>
# - Auto PR creation and merge
# - Loop closure via workflow_dispatch
# - Wave progression (wave 1 → wave 2)
# - Parallel task execution
# - Final PR creation (feature/<N>-<slug> → main)
# - Reaction 👀 on /agents execute trigger comment (workflow started)
# - Reaction 👍 after final PR opens (workflow succeeded)
# - /agents close tears down branches, PRs, and tasks (when --cleanup)
#
# NOT COVERED (planned for a separate test harness):
# - /agents devise end-to-end (this test skips planning, creates issues directly)
# - Native issue types (Feature / Task) — set by the tactical-agent reconcile step
# - Sub-issue relationships — same reason
# - /agents revert path
# =============================================================================

set -euo pipefail

CLEANUP=false
WAIT=true
REPO=""
FORMAT="yaml"  # yaml | md
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
PREFIX="smoke-${TIMESTAMP}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cleanup) CLEANUP=true; shift ;;
    --no-wait) WAIT=false; shift ;;
    --repo) REPO="$2"; shift 2 ;;
    --format) FORMAT="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,40p' "$0"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ "$FORMAT" != "yaml" && "$FORMAT" != "md" ]]; then
  echo "Invalid format: $FORMAT (expected 'yaml' or 'md')" >&2
  exit 1
fi

REPO_ARG=""
if [[ -n "$REPO" ]]; then
  REPO_ARG="--repo $REPO"
fi

echo "=== Smoke Test — Agentic Workflow ==="
echo "Repo: ${REPO:-$(gh repo view --json nameWithOwner --jq '.nameWithOwner')}"
echo "Prefix: $PREFIX"
echo ""

# --- Ensure labels exist ---
echo "[1/5] Ensuring labels exist..."
gh label create "Ready"   --color "0E8A16" --description "Plan complete, ready for execution" $REPO_ARG 2>/dev/null || true
gh label create "smoke-test" --color "FFA500" --description "Smoke test" $REPO_ARG 2>/dev/null || true
gh label create "priority:P0" --color "B60205" --description "Critical" $REPO_ARG 2>/dev/null || true

# --- Create task issues ---
echo "[2/5] Creating task issues..."

TASK1_URL=$(gh issue create $REPO_ARG \
  --title "Smoke ${TIMESTAMP}: Create test/${PREFIX}-1.md" \
  --label "smoke-test,priority:P0" \
  --body "## Task

Create a new file at \`test/${PREFIX}-1.md\` with the following content:

\`\`\`
smoke test ${TIMESTAMP}
\`\`\`

## Acceptance Criteria

- [ ] File \`test/${PREFIX}-1.md\` exists
- [ ] Contains the text 'smoke test ${TIMESTAMP}'

## Dependencies

None — first task.")
TASK1=$(echo "$TASK1_URL" | grep -oE '[0-9]+$')
echo "  Task 1: #$TASK1"

TASK2_URL=$(gh issue create $REPO_ARG \
  --title "Smoke ${TIMESTAMP}: Append to test/${PREFIX}-1.md" \
  --label "smoke-test,priority:P0" \
  --body "## Task

Append the line \`wave 2 done\` to \`test/${PREFIX}-1.md\`.

## Acceptance Criteria

- [ ] File contains both 'smoke test ${TIMESTAMP}' and 'wave 2 done'

## Dependencies

- Depends on #${TASK1} (file must exist first)")
TASK2=$(echo "$TASK2_URL" | grep -oE '[0-9]+$')
echo "  Task 2: #$TASK2"

TASK3_URL=$(gh issue create $REPO_ARG \
  --title "Smoke ${TIMESTAMP}: Create test/${PREFIX}-2.md" \
  --label "smoke-test,priority:P0" \
  --body "## Task

Create a new file at \`test/${PREFIX}-2.md\` with the content:

\`\`\`
second file
\`\`\`

## Acceptance Criteria

- [ ] File \`test/${PREFIX}-2.md\` exists
- [ ] Contains 'second file'

## Dependencies

- Depends on #${TASK1} (Wave 2, parallel with #${TASK2})")
TASK3=$(echo "$TASK3_URL" | grep -oE '[0-9]+$')
echo "  Task 3: #$TASK3"

# --- Create feature issue ---
echo "[3/5] Creating feature issue..."

if [[ "$FORMAT" == "yaml" ]]; then
  META_BODY=$(cat <<EOF
## Purpose

Smoke test (YAML format) for the agentic workflow — validates the full autonomous loop end-to-end.

Generated by \`smoke-test.sh --format yaml\` at ${TIMESTAMP}.

## Plan

\`\`\`yaml
waves:
  - name: Foundation
    tasks: [${TASK1}]
  - name: Parallel
    tasks: [${TASK2}, ${TASK3}]
\`\`\`

## Progress

- [ ] #${TASK1} Create test/${PREFIX}-1.md \`P0\`
- [ ] #${TASK2} Append to test/${PREFIX}-1.md \`P0\`
- [ ] #${TASK3} Create test/${PREFIX}-2.md \`P0\`

## Notes

- All tasks are P0 — auto-merge enabled
- Final PR \`feature/<this_issue>\` → \`main\` opens automatically
EOF
)
else
  META_BODY=$(cat <<EOF
## Purpose

Smoke test (markdown format) for the agentic workflow — validates the full autonomous loop end-to-end.

Generated by \`smoke-test.sh --format md\` at ${TIMESTAMP}.

## Plan

## Wave 1 — Foundation
- [ ] #${TASK1} Create test/${PREFIX}-1.md \`P0\`

## Wave 2: Parallel
- [ ] #${TASK2} Append to test/${PREFIX}-1.md \`P0\`
- [ ] #${TASK3} Create test/${PREFIX}-2.md \`P0\`

## Notes

- All tasks are P0 — auto-merge enabled
- Final PR \`feature/<this_issue>\` → \`main\` opens automatically
EOF
)
fi

META_URL=$(gh issue create $REPO_ARG \
  --title "Feature: Smoke Test ${TIMESTAMP}" \
  --label "Ready,smoke-test" \
  --body "$META_BODY")
FEATURE=$(echo "$META_URL" | grep -oE '[0-9]+$')
echo "  Feature: #$FEATURE"

# Set issue type to Feature (workflow guards check type, not label)
REPO_NAME="${REPO:-$(gh repo view --json nameWithOwner --jq '.nameWithOwner')}"
gh api "repos/$REPO_NAME/issues/$FEATURE" --method PATCH -f "type=Feature" --silent 2>/dev/null \
  || echo "  ⚠️  Could not set issue type=Feature (types may not be configured at the org)"

# --- Kickstart ---
echo "[4/5] Kickstarting the loop..."
KICKSTART_URL=$(gh issue comment $FEATURE $REPO_ARG --body "/agents execute")
KICKSTART_ID=$(echo "$KICKSTART_URL" | grep -oE 'issuecomment-[0-9]+' | grep -oE '[0-9]+$' || echo "")
echo "  Kickstart comment posted (id: ${KICKSTART_ID:-unknown})."

# --- Assert 👀 reaction appears on the kickstart comment ---
# Feature orchestrator adds `eyes` as its first reaction step. If it doesn't
# appear within 60s, the trigger guard likely didn't match — fail fast.
if [[ -n "$KICKSTART_ID" ]]; then
  echo "  Waiting for 👀 reaction on kickstart comment..."
  REACTION_WAITED=0
  while [[ $REACTION_WAITED -lt 60 ]]; do
    EYES=$(gh api "repos/$(gh repo view ${REPO:-} --json nameWithOwner --jq '.nameWithOwner')/issues/comments/$KICKSTART_ID/reactions" \
      --jq '[.[] | select(.content == "eyes")] | length' 2>/dev/null || echo "0")
    if [[ "$EYES" -gt 0 ]]; then
      echo "  ✅ 👀 reaction detected (${REACTION_WAITED}s)"
      break
    fi
    sleep 5
    REACTION_WAITED=$((REACTION_WAITED + 5))
  done
  if [[ "$EYES" -eq 0 ]]; then
    echo "  ⚠️  No 👀 reaction after 60s — orchestrator may not have picked up the comment"
  fi
fi

if [[ "$WAIT" == false ]]; then
  echo ""
  echo "=== Smoke test initiated ==="
  echo "Feature issue: $META_URL"
  echo "Skipping wait (--no-wait)."
  exit 0
fi

# --- Wait for completion ---
echo "[5/5] Waiting for smoke test to complete..."
echo "  Polling every 30s (max 30 minutes)..."

MAX_WAIT=1800
WAITED=0
INTERVAL=30

while [[ $WAITED -lt $MAX_WAIT ]]; do
  sleep $INTERVAL
  WAITED=$((WAITED + INTERVAL))

  # Check if final PR is open (branch may have a slug suffix: feature/123-slug)
  FINAL_PR=$(gh pr list $REPO_ARG \
    --base main \
    --state all \
    --json number,state,headRefName \
    --jq "[.[] | select(.headRefName | startswith(\"feature/${FEATURE}\"))] | .[0] // empty")

  if [[ -n "$FINAL_PR" ]]; then
    PR_NUM=$(echo "$FINAL_PR" | jq -r '.number')
    PR_STATE=$(echo "$FINAL_PR" | jq -r '.state')
    echo "  Final PR #$PR_NUM found (state: $PR_STATE) after ${WAITED}s"

    if [[ "$PR_STATE" == "OPEN" || "$PR_STATE" == "MERGED" ]]; then
      echo ""
      echo "=== ✅ Smoke test SUCCEEDED ==="
      echo "Final PR: $PR_NUM"

      if [[ "$CLEANUP" == true ]]; then
        echo ""
        echo "Cleaning up via /agents close (also exercises the close workflow)..."

        # First close the final feature PR if it's still open — /agents close
        # will close it too, but doing it here avoids a GitHub-API race.
        gh pr close $PR_NUM $REPO_ARG --comment "Smoke test validated — closing." 2>/dev/null || true

        # Trigger /agents close on the feature issue
        gh issue comment $FEATURE $REPO_ARG --body "/agents close"
        echo "  /agents close triggered. Waiting for teardown..."

        # Poll for feature issue closed state (up to 60s)
        CLOSE_WAITED=0
        while [[ $CLOSE_WAITED -lt 60 ]]; do
          STATE=$(gh issue view $FEATURE $REPO_ARG --json state --jq '.state' 2>/dev/null || echo "")
          if [[ "$STATE" == "CLOSED" ]]; then
            echo "  ✅ Feature issue closed (${CLOSE_WAITED}s)"
            break
          fi
          sleep 5
          CLOSE_WAITED=$((CLOSE_WAITED + 5))
        done

        if [[ "$STATE" != "CLOSED" ]]; then
          echo "  ⚠️  /agents close didn't finish within 60s — falling back to manual cleanup"
          for i in $TASK1 $TASK2 $TASK3 $FEATURE; do
            gh issue close $i $REPO_ARG --comment "Smoke test cleanup" 2>/dev/null || true
          done
          for b in $(gh api "repos/$(gh repo view ${REPO:-} --json nameWithOwner --jq '.nameWithOwner')/git/matching-refs/heads/feature/${FEATURE}-" --jq '.[].ref | sub("refs/heads/"; "")' 2>/dev/null); do
            git push origin --delete "$b" 2>/dev/null || true
          done
        fi
        echo "Cleanup complete."
      fi

      exit 0
    fi
  fi

  echo "  Still waiting... (${WAITED}s / ${MAX_WAIT}s)"
done

echo ""
echo "=== ❌ Smoke test TIMED OUT after ${MAX_WAIT}s ==="
echo "Check feature issue #$FEATURE for status."
exit 1
