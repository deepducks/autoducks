#!/usr/bin/env bash
# =============================================================================
# Smoke Test — Agentic Workflow Validator
# =============================================================================
#
# PURPOSE
# -------
# Generic smoke test for the autoducks-maestro / autoducks-developer / autoducks-fix
# workflow trio. Creates a feature issue with 3 trivial tasks in 2 waves, kickstarts the
# orchestrator, and optionally waits for completion.
#
# USAGE
# -----
#   ./smoke-test.sh [OPTIONS]
#
# OPTIONS
#   --cleanup         Close issues/PR and delete branches after test completes
#   --no-wait         Create issues and kickstart, don't wait for completion
#   --repo OWNER/REPO Target repo (default: current repo from `gh`)
#   --security        Run allowed-path + denied-path security scenarios instead of
#                     the golden path; requires SOCK_PUPPET_TOKEN (see REQUIREMENTS)
#   -h, --help        Show this help
#
# REQUIREMENTS
# ------------
# - gh CLI authenticated with repo access
# - autoducks-maestro.yml, autoducks-developer.yml, autoducks-fix.yml workflows installed
# - `Feature`, `Tactics:done`, and `smoke-test` labels (created automatically if missing)
# - ANTHROPIC_API_KEY secret configured
# - Claude Code GitHub App installed on the repo
# - Actions permission "Read and write" enabled
# - SOCK_PUPPET_TOKEN  (--security only) Classic PAT for a GitHub account that has
#                      NONE association on the target repo. Needs `public_repo` scope
#                      (or `repo` for private repos). See:
#                      docs/src/content/docs/reference/security.mdx
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
# - Wave orchestrator kickstart via /execute comment
# - Task worker triggered by wave dispatch
# - Branch creation under feature/<N>-<slug>/task/<T>-<slug>
# - Auto PR creation and merge
# - Loop closure via workflow_dispatch
# - Wave progression (wave 1 → wave 2)
# - Parallel task execution
# - Final PR creation (feature/<N>-<slug> → main)
# - Reaction 👀 on /execute trigger comment (workflow started)
# - Reaction 👍 after final PR opens (workflow succeeded)
# - /close tears down branches, PRs, and tasks (when --cleanup)
#
# NOT COVERED (planned for a separate test harness):
# - /engineer end-to-end (this test skips planning, creates issues directly)
# - Native issue types (Feature / Task) — set by the tactical-agent reconcile step
# - Sub-issue relationships — same reason
# - /revert path
# =============================================================================

set -euo pipefail

CLEANUP=false
WAIT=true
REPO=""
FORMAT="yaml"  # yaml | md
SECURITY=false
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
PREFIX="smoke-${TIMESTAMP}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cleanup) CLEANUP=true; shift ;;
    --no-wait) WAIT=false; shift ;;
    --repo) REPO="$2"; shift 2 ;;
    --format) FORMAT="$2"; shift 2 ;;
    --security) SECURITY=true; shift ;;
    -h|--help)
      sed -n '2,46p' "$0"
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
else
  REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../.autoducks/core/config/label-utils.sh"

# =============================================================================
# Security scenarios (--security flag)
# =============================================================================
if [[ "$SECURITY" == true ]]; then
  if [[ -z "${SOCK_PUPPET_TOKEN:-}" ]]; then
    echo "Error: --security requires SOCK_PUPPET_TOKEN to be set." >&2
    echo "  Generate a classic PAT (public_repo scope) for a GitHub account with" >&2
    echo "  NONE association on the target repo and export it as SOCK_PUPPET_TOKEN." >&2
    echo "  See: docs/src/content/docs/reference/security.mdx" >&2
    exit 1
  fi

  REPO_NAME="${REPO:-$(gh repo view --json nameWithOwner --jq '.nameWithOwner')}"
  SECURITY_PASS=true

  echo "=== Smoke Test — Security Scenarios ==="
  echo "Repo: $REPO_NAME"
  echo "Prefix: $PREFIX"
  echo ""

  # Ensure labels exist
  label::ensure "Tactics:done" "D93F0B" "Tactical plan complete" || echo "Warning: failed to ensure label 'Tactics:done'" >&2
  label::ensure "smoke-test" "FFA500" "Smoke test" || echo "Warning: failed to ensure label 'smoke-test'" >&2
  gh label create "priority:P0" --color "B60205" --description "Critical" $REPO_ARG 2>/dev/null || true

  # ---------------------------------------------------------------------------
  # Scenario A — Authorized trigger: runner posts /execute → proceeds
  # ---------------------------------------------------------------------------
  echo "--- Scenario A: Authorized trigger ---"

  TASK_SEC_URL=$(gh issue create $REPO_ARG \
    --title "Smoke-sec ${TIMESTAMP}: Create test/${PREFIX}-sec.md" \
    --label "smoke-test,priority:P0" \
    --body "## Task

Create a new file at \`test/${PREFIX}-sec.md\` with the following content:

\`\`\`
security smoke test ${TIMESTAMP}
\`\`\`

## Acceptance Criteria

- [ ] File \`test/${PREFIX}-sec.md\` exists

## Dependencies

None")
  TASK_SEC=$(echo "$TASK_SEC_URL" | grep -oE '[0-9]+$')
  echo "  Task: #$TASK_SEC"

  FEATURE_A_URL=$(gh issue create $REPO_ARG \
    --title "Security Scenario A: Authorized ${TIMESTAMP}" \
    --label "Feature,Tactics:done,smoke-test" \
    --body "## Purpose

Security smoke test — authorized trigger path.

## Plan

\`\`\`yaml
waves:
  - name: Security
    tasks: [${TASK_SEC}]
\`\`\`

## Progress

- [ ] #${TASK_SEC} Create test/${PREFIX}-sec.md \`P0\`")
  FEATURE_A=$(echo "$FEATURE_A_URL" | grep -oE '[0-9]+$')
  echo "  Feature: #$FEATURE_A"

  gh api "repos/$REPO_NAME/issues/$FEATURE_A" --method PATCH -f "type=Feature" --silent 2>/dev/null \
    || echo "  ⚠️  Could not set issue type=Feature"

  COMMENT_A_URL=$(gh issue comment $FEATURE_A $REPO_ARG --body "/execute")
  COMMENT_A_ID=$(echo "$COMMENT_A_URL" | grep -oE 'issuecomment-[0-9]+' | grep -oE '[0-9]+$' || echo "")
  echo "  Kickstart comment posted (id: ${COMMENT_A_ID:-unknown})"

  # Wait for 👀 reaction
  if [[ -n "$COMMENT_A_ID" ]]; then
    echo "  Waiting for 👀 reaction..."
    A_EYES_WAITED=0; A_EYES=0
    while [[ $A_EYES_WAITED -lt 60 ]]; do
      A_EYES=$(gh api "repos/$REPO_NAME/issues/comments/$COMMENT_A_ID/reactions" \
        --jq '[.[] | select(.content == "eyes")] | length' 2>/dev/null || echo "0")
      [[ "$A_EYES" -gt 0 ]] && break
      sleep 5
      A_EYES_WAITED=$((A_EYES_WAITED + 5))
    done
    if [[ "$A_EYES" -gt 0 ]]; then
      echo "  ✅ 👀 reaction detected (${A_EYES_WAITED}s) — workflow triggered"
    else
      echo "  ⚠️  No 👀 reaction after 60s — orchestrator may not have triggered"
    fi
  fi

  # Wait for PR (up to 30 minutes, reusing same cadence as golden path)
  echo "  Waiting for PR to open (max 30 minutes)..."
  A_MAX=1800; A_WAITED=0; A_INTERVAL=30; A_PASS=false
  while [[ $A_WAITED -lt $A_MAX ]]; do
    sleep $A_INTERVAL
    A_WAITED=$((A_WAITED + A_INTERVAL))

    A_PR=$(gh pr list $REPO_ARG \
      --base main --state all \
      --json number,state,headRefName \
      --jq "[.[] | select(.headRefName | startswith(\"feature/${FEATURE_A}\"))] | .[0] // empty")

    if [[ -n "$A_PR" ]]; then
      A_PR_STATE=$(echo "$A_PR" | jq -r '.state')
      if [[ "$A_PR_STATE" == "OPEN" || "$A_PR_STATE" == "MERGED" ]]; then
        A_PR_NUM=$(echo "$A_PR" | jq -r '.number')
        echo "  ✅ Scenario A PASSED: PR #$A_PR_NUM (${A_WAITED}s)"
        A_PASS=true
        break
      fi
    fi

    echo "  Still waiting... (${A_WAITED}s / ${A_MAX}s)"
  done

  if [[ "$A_PASS" == false ]]; then
    echo "  ❌ Scenario A FAILED: No PR opened after ${A_MAX}s"
    SECURITY_PASS=false
  fi

  echo ""

  # ---------------------------------------------------------------------------
  # Scenario B — Denied trigger: sock-puppet (NONE) posts /execute
  # ---------------------------------------------------------------------------
  echo "--- Scenario B: Unauthorized trigger (sock-puppet, NONE association) ---"

  FEATURE_B_URL=$(gh issue create $REPO_ARG \
    --title "Security Scenario B: Denied ${TIMESTAMP}" \
    --label "Feature,Tactics:done,smoke-test" \
    --body "Sandbox issue — tests that /execute from an unauthorized account is denied by the Authorization Gate.")
  FEATURE_B=$(echo "$FEATURE_B_URL" | grep -oE '[0-9]+$')
  echo "  Sandbox feature: #$FEATURE_B"

  gh api "repos/$REPO_NAME/issues/$FEATURE_B" --method PATCH -f "type=Feature" --silent 2>/dev/null \
    || echo "  ⚠️  Could not set issue type=Feature"

  # Capture timestamp before posting for workflow run lookup
  B_RUN_BEFORE=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  echo "  Posting /execute as sock-puppet (NONE association)..."
  B_COMMENT_ID=$(GH_TOKEN="$SOCK_PUPPET_TOKEN" gh api \
    "repos/$REPO_NAME/issues/$FEATURE_B/comments" \
    --method POST \
    -f "body=/execute" \
    --jq '.id' 2>/dev/null || echo "")

  if [[ -z "$B_COMMENT_ID" ]]; then
    echo "  ❌ Failed to post comment with SOCK_PUPPET_TOKEN — verify the token and repo URL"
    SECURITY_PASS=false
  else
    echo "  Sock-puppet comment posted (id: $B_COMMENT_ID)"

    # (a) Poll for 👎 reaction on trigger comment
    echo "  (a) Waiting for 👎 reaction on trigger comment (max 120s)..."
    B_THUMBS_WAITED=0; B_THUMBS=0
    while [[ $B_THUMBS_WAITED -lt 120 ]]; do
      B_THUMBS=$(gh api "repos/$REPO_NAME/issues/comments/$B_COMMENT_ID/reactions" \
        --jq '[.[] | select(.content == "-1")] | length' 2>/dev/null || echo "0")
      [[ "$B_THUMBS" -gt 0 ]] && break
      sleep 5
      B_THUMBS_WAITED=$((B_THUMBS_WAITED + 5))
    done
    if [[ "$B_THUMBS" -gt 0 ]]; then
      echo "  ✅ (a) 👎 reaction found (${B_THUMBS_WAITED}s)"
    else
      echo "  ❌ (a) No 👎 reaction after 120s"
      SECURITY_PASS=false
    fi

    # (b) Poll for denial comment matching denial-message.md template
    echo "  (b) Waiting for denial comment (max 120s)..."
    B_DENIAL_WAITED=0; B_DENIAL=0
    while [[ $B_DENIAL_WAITED -lt 120 ]]; do
      B_DENIAL=$(gh api "repos/$REPO_NAME/issues/$FEATURE_B/comments" \
        --jq '[.[] | select(.body | contains("Agent not run"))] | length' 2>/dev/null || echo "0")
      [[ "$B_DENIAL" -gt 0 ]] && break
      sleep 5
      B_DENIAL_WAITED=$((B_DENIAL_WAITED + 5))
    done
    if [[ "$B_DENIAL" -gt 0 ]]; then
      echo "  ✅ (b) Denial comment found (${B_DENIAL_WAITED}s)"
    else
      echo "  ❌ (b) No denial comment after 120s"
      SECURITY_PASS=false
    fi

    # (c) Assert no branch created for this feature
    B_BRANCHES=$(gh api "repos/$REPO_NAME/git/matching-refs/heads/feature/${FEATURE_B}" \
      --jq 'length' 2>/dev/null || echo "0")
    if [[ "${B_BRANCHES:-0}" -eq 0 ]]; then
      echo "  ✅ (c) No branch created for feature #$FEATURE_B"
    else
      echo "  ❌ (c) Unexpected branch(es) found for feature #$FEATURE_B"
      SECURITY_PASS=false
    fi

    # (d) Assert no PR opened for this feature
    B_PRS=$(gh pr list $REPO_ARG \
      --state all \
      --json number,headRefName \
      --jq "[.[] | select(.headRefName | startswith(\"feature/${FEATURE_B}\"))] | length")
    if [[ "${B_PRS:-0}" -eq 0 ]]; then
      echo "  ✅ (d) No PR opened for feature #$FEATURE_B"
    else
      echo "  ❌ (d) Unexpected PR(s) found for feature #$FEATURE_B"
      SECURITY_PASS=false
    fi

    # (e) Assert LLM step (Run orchestrator) was skipped via workflow run inspection
    echo "  (e) Checking workflow run for skipped LLM step..."
    B_RUN_ID=""; B_RUN_WAIT=0
    while [[ $B_RUN_WAIT -lt 120 && -z "$B_RUN_ID" ]]; do
      B_RUN_ID=$(gh api "repos/$REPO_NAME/actions/runs?event=issue_comment&per_page=20" 2>/dev/null \
        | jq -r --arg before "$B_RUN_BEFORE" \
          '[.workflow_runs[] | select(.created_at >= $before and (.name | contains("Wave Orchestrator")))] | .[0].id // empty')
      [[ -n "$B_RUN_ID" ]] && break
      sleep 10
      B_RUN_WAIT=$((B_RUN_WAIT + 10))
    done

    if [[ -n "$B_RUN_ID" ]]; then
      # Wait for the run to reach completed state
      B_DONE_WAIT=0
      while [[ $B_DONE_WAIT -lt 120 ]]; do
        B_RUN_STATUS=$(gh api "repos/$REPO_NAME/actions/runs/$B_RUN_ID" \
          --jq '.status' 2>/dev/null || echo "")
        [[ "$B_RUN_STATUS" == "completed" ]] && break
        sleep 10
        B_DONE_WAIT=$((B_DONE_WAIT + 10))
      done

      B_ORCH_STEP=$(gh api "repos/$REPO_NAME/actions/runs/$B_RUN_ID/jobs" 2>/dev/null \
        | jq -r '.jobs[].steps[] | select(.name == "Run orchestrator") | .conclusion // empty' \
        | head -1)

      if [[ "$B_ORCH_STEP" == "skipped" ]]; then
        echo "  ✅ (e) LLM step (Run orchestrator) was skipped (authz.outcome != success)"
      else
        echo "  ❌ (e) LLM step conclusion: ${B_ORCH_STEP:-not_found}"
        SECURITY_PASS=false
      fi
    else
      echo "  ⚠️  (e) Wave Orchestrator run not found after ${B_RUN_WAIT}s — skipping LLM step check"
    fi
  fi

  echo ""

  # Cleanup (respects --cleanup flag)
  if [[ "$CLEANUP" == true ]]; then
    echo "Cleaning up security test issues..."
    for i in "${TASK_SEC:-}" "${FEATURE_A:-}" "${FEATURE_B:-}"; do
      [[ -n "$i" ]] && gh issue close "$i" $REPO_ARG --comment "Security smoke test cleanup." 2>/dev/null || true
    done
    echo "Cleanup complete."
    echo ""
  fi

  # Final result
  if [[ "$SECURITY_PASS" == true ]]; then
    echo "=== ✅ Security Scenarios PASSED ==="
    exit 0
  else
    echo "=== ❌ Security Scenarios FAILED ==="
    exit 1
  fi
fi

echo "=== Smoke Test — Agentic Workflow ==="
echo "Repo: ${REPO:-$(gh repo view --json nameWithOwner --jq '.nameWithOwner')}"
echo "Prefix: $PREFIX"
echo ""

# --- Ensure labels exist ---
echo "[1/5] Ensuring labels exist..."
label::ensure "Tactics:done" "D93F0B" "Tactical plan complete" || echo "Warning: failed to ensure label 'Tactics:done'" >&2
label::ensure "smoke-test" "FFA500" "Smoke test" || echo "Warning: failed to ensure label 'smoke-test'" >&2
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
  --label "Feature,Tactics:done,smoke-test" \
  --body "$META_BODY")
FEATURE=$(echo "$META_URL" | grep -oE '[0-9]+$')
echo "  Feature: #$FEATURE"

# Set issue type to Feature (workflow guards check type, not label)
REPO_NAME="${REPO:-$(gh repo view --json nameWithOwner --jq '.nameWithOwner')}"
gh api "repos/$REPO_NAME/issues/$FEATURE" --method PATCH -f "type=Feature" --silent 2>/dev/null \
  || echo "  ⚠️  Could not set issue type=Feature (types may not be configured at the org)"

# --- Kickstart ---
echo "[4/5] Kickstarting the loop..."
KICKSTART_URL=$(gh issue comment $FEATURE $REPO_ARG --body "/execute")
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
        echo "Cleaning up via /close (also exercises the close workflow)..."

        # First close the final feature PR if it's still open — /close
        # will close it too, but doing it here avoids a GitHub-API race.
        gh pr close $PR_NUM $REPO_ARG --comment "Smoke test validated — closing." 2>/dev/null || true

        # Trigger /close on the feature issue
        gh issue comment $FEATURE $REPO_ARG --body "/close"
        echo "  /close triggered. Waiting for teardown..."

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
          echo "  ⚠️  /close didn't finish within 60s — falling back to manual cleanup"
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
