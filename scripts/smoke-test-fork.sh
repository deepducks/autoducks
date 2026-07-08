#!/usr/bin/env bash
# =============================================================================
# Smoke Test — Fork-Mode Decoupling Invariant Validator
# =============================================================================
#
# PURPOSE
# -------
# Repeatable fork-mode smoke test for the `base_branch` / `integration_branch`
# decoupling (see the Appendix B invariant in the design zone of the feature
# that introduced `integration_branch`). Seeds a `build` integration branch
# off `main`, temporarily configures `integration_branch: "build"` on the
# default branch, drives the tactical → wave → execution loop with a single
# trivial task, and asserts:
#
#   1. The feature branch is rebasable onto the base (cut-point):
#        git merge-base --is-ancestor main feature/<N>-<slug>
#   2. The feature branch carries only feature work (no build-only commits):
#        git log --oneline main..feature/<N>-<slug>
#   3. The feature PR targets the integration branch:
#        gh pr view <pr-num> --json baseRefName --jq .baseRefName   # → "build"
#   4. The invariant itself:
#        [ "$(git merge-base feature/<N>-<slug> build)" = "$(git rev-parse main)" ]
#
# USAGE
# -----
#   ./smoke-test-fork.sh [OPTIONS]
#
# Run from a local clone of the target repo with `origin` pointing at it —
# the script uses local `git` (fetch/merge-base/log) against `origin/*` refs
# in addition to `gh`.
#
# OPTIONS
#   --cleanup         Close issues/PR, delete seeded branches (including
#                      `build`) after the test completes
#   --no-wait         Create issues and kickstart, don't wait for completion
#                      (leaves `integration_branch: "build"` in place on the
#                      default branch — see the printed revert command)
#   --repo OWNER/REPO Target repo (default: current repo from `gh`)
#   -h, --help        Show this help
#
# REQUIREMENTS
# ------------
# - Everything scripts/smoke-test.sh requires (gh CLI, workflows, labels,
#   ANTHROPIC_API_KEY, Claude Code GitHub App, Actions read/write)
# - A local clone with `origin` set to the target repo and push access
# - IMPORTANT: this script pushes a commit to the target repo's default
#   branch that sets `defaults.integration_branch = "build"` in
#   `.autoducks/autoducks.json`, so that the tactical/wave/execution agents
#   (which always check out the default branch) pick it up. It reverts that
#   commit automatically once the test completes. Run this against a
#   disposable/scratch repo, not a repo other people rely on concurrently.
#
# VALIDATION SCENARIO
# --------------------
# Single task, single wave:
#   Task 1: Create a new file
#
# This validates:
# - `build` seeded as a clean fork of `main`
# - Tactical/Wave Orchestrator cut the feature branch from `base_branch` (main)
# - Feature PR (and task PR) target `integration_branch` (build), not main
# - merge-base(feature, build) == base_branch tip (the decoupling invariant)
# - `/quack close` tears down branches, PRs, and tasks (when --cleanup)
#
# NOT COVERED (see scripts/smoke-test.sh for the full golden-path coverage)
# =============================================================================

set -euo pipefail

CLEANUP=false
WAIT=true
REPO=""
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
PREFIX="smoke-fork-${TIMESTAMP}"
DEFAULT_BRANCH="main"
INTEGRATION_BRANCH="build"
CONFIG_PATH=".autoducks/autoducks.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cleanup) CLEANUP=true; shift ;;
    --no-wait) WAIT=false; shift ;;
    --repo) REPO="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,66p' "$0"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

REPO_ARG=""
if [[ -n "$REPO" ]]; then
  REPO_ARG="--repo $REPO"
fi
REPO_NAME="${REPO:-$(gh repo view --json nameWithOwner --jq '.nameWithOwner')}"

echo "=== Smoke Test — Fork-Mode Decoupling Invariant ==="
echo "Repo: $REPO_NAME"
echo "Prefix: $PREFIX"
echo ""

# --- Revert-on-exit guard for the config override ---
CONFIG_CHANGED=false
ORIG_CONTENT_B64=""

revert_config() {
  if [[ "$CONFIG_CHANGED" == true ]]; then
    echo "Reverting $CONFIG_PATH on $DEFAULT_BRANCH..."
    local cur_sha
    cur_sha=$(gh api "repos/$REPO_NAME/contents/$CONFIG_PATH?ref=$DEFAULT_BRANCH" --jq '.sha')
    gh api "repos/$REPO_NAME/contents/$CONFIG_PATH" --method PUT \
      -f message="smoke-test-fork: revert integration_branch override (${TIMESTAMP})" \
      -f content="$ORIG_CONTENT_B64" \
      -f sha="$cur_sha" \
      -f branch="$DEFAULT_BRANCH" >/dev/null
    echo "  Reverted."
  fi
}
trap revert_config EXIT

# --- Ensure labels exist ---
echo "[1/7] Ensuring labels exist..."
gh label create "Tactics:done" --color "D93F0B" --description "Tactical plan complete" $REPO_ARG 2>/dev/null || true
gh label create "smoke-test" --color "FFA500" --description "Smoke test" $REPO_ARG 2>/dev/null || true
gh label create "priority:P0" --color "B60205" --description "Critical" $REPO_ARG 2>/dev/null || true

# --- Configure integration_branch: "build" on the default branch ---
echo "[2/7] Configuring integration_branch=\"$INTEGRATION_BRANCH\" on $DEFAULT_BRANCH..."
CONFIG_RESP=$(gh api "repos/$REPO_NAME/contents/$CONFIG_PATH?ref=$DEFAULT_BRANCH")
ORIG_SHA=$(echo "$CONFIG_RESP" | jq -r '.sha')
ORIG_CONTENT_B64=$(echo "$CONFIG_RESP" | jq -r '.content' | tr -d '\n')
ORIG_CONTENT=$(echo "$ORIG_CONTENT_B64" | base64 -d)
CURRENT_INTEGRATION_BRANCH=$(echo "$ORIG_CONTENT" | jq -r '.defaults.integration_branch // .defaults.base_branch // empty')

if [[ "$CURRENT_INTEGRATION_BRANCH" == "$INTEGRATION_BRANCH" ]]; then
  echo "  Already configured — skipping commit."
  CONFIG_COMMIT_SHA=""
else
  NEW_CONTENT=$(echo "$ORIG_CONTENT" | jq --arg b "$INTEGRATION_BRANCH" '.defaults.integration_branch = $b')
  NEW_CONTENT_B64=$(echo "$NEW_CONTENT" | base64 -w0)
  COMMIT_RESP=$(gh api "repos/$REPO_NAME/contents/$CONFIG_PATH" --method PUT \
    -f message="smoke-test-fork: set integration_branch=$INTEGRATION_BRANCH (${TIMESTAMP})" \
    -f content="$NEW_CONTENT_B64" \
    -f sha="$ORIG_SHA" \
    -f branch="$DEFAULT_BRANCH")
  CONFIG_COMMIT_SHA=$(echo "$COMMIT_RESP" | jq -r '.commit.sha')
  CONFIG_CHANGED=true
  echo "  Committed (sha: $CONFIG_COMMIT_SHA)."
fi

# --- Seed the build branch from the default branch tip ---
echo "[3/7] Seeding \"$INTEGRATION_BRANCH\" branch off $DEFAULT_BRANCH..."
MAIN_SHA="${CONFIG_COMMIT_SHA:-$(gh api "repos/$REPO_NAME/git/ref/heads/$DEFAULT_BRANCH" --jq '.object.sha')}"
if gh api "repos/$REPO_NAME/git/ref/heads/$INTEGRATION_BRANCH" >/dev/null 2>&1; then
  gh api "repos/$REPO_NAME/git/refs/heads/$INTEGRATION_BRANCH" --method PATCH \
    -f sha="$MAIN_SHA" -F force=true >/dev/null
  echo "  Reset existing \"$INTEGRATION_BRANCH\" to $DEFAULT_BRANCH tip ($MAIN_SHA)."
else
  gh api "repos/$REPO_NAME/git/refs" --method POST \
    -f ref="refs/heads/$INTEGRATION_BRANCH" -f sha="$MAIN_SHA" >/dev/null
  echo "  Created \"$INTEGRATION_BRANCH\" at $DEFAULT_BRANCH tip ($MAIN_SHA)."
fi

# --- Create task + feature issues ---
echo "[4/7] Creating task and feature issues..."

TASK1_URL=$(gh issue create $REPO_ARG \
  --title "Smoke-fork ${TIMESTAMP}: Create test/${PREFIX}-1.md" \
  --label "smoke-test,priority:P0" \
  --body "## Task

Create a new file at \`test/${PREFIX}-1.md\` with the following content:

\`\`\`
fork smoke test ${TIMESTAMP}
\`\`\`

## Acceptance Criteria

- [ ] File \`test/${PREFIX}-1.md\` exists
- [ ] Contains the text 'fork smoke test ${TIMESTAMP}'

## Dependencies

None — first task.")
TASK1=$(echo "$TASK1_URL" | grep -oE '[0-9]+$')
echo "  Task 1: #$TASK1"

META_BODY=$(cat <<EOF
## Purpose

Fork-mode smoke test for the decoupling invariant — validates that the
feature branch is cut from \`base_branch\` while the feature PR targets
\`integration_branch\`.

Generated by \`smoke-test-fork.sh\` at ${TIMESTAMP}.

## Plan

\`\`\`yaml
waves:
  - name: Foundation
    tasks: [${TASK1}]
\`\`\`

## Progress

- [ ] #${TASK1} Create test/${PREFIX}-1.md \`P0\`

## Notes

- Task is P0 — auto-merge enabled
- Final PR \`feature/<this_issue>\` → \`${INTEGRATION_BRANCH}\` opens automatically
EOF
)

META_URL=$(gh issue create $REPO_ARG \
  --title "Feature: Fork Smoke Test ${TIMESTAMP}" \
  --label "Feature,Tactics:done,smoke-test" \
  --body "$META_BODY")
FEATURE=$(echo "$META_URL" | grep -oE '[0-9]+$')
echo "  Feature: #$FEATURE"

gh api "repos/$REPO_NAME/issues/$FEATURE" --method PATCH -f "type=Feature" --silent 2>/dev/null \
  || echo "  ⚠️  Could not set issue type=Feature (types may not be configured at the org)"

# --- Kickstart ---
echo "[5/7] Kickstarting the loop..."
KICKSTART_URL=$(gh issue comment $FEATURE $REPO_ARG --body "/quack execute")
KICKSTART_ID=$(echo "$KICKSTART_URL" | grep -oE 'issuecomment-[0-9]+' | grep -oE '[0-9]+$' || echo "")
echo "  Kickstart comment posted (id: ${KICKSTART_ID:-unknown})."

if [[ -n "$KICKSTART_ID" ]]; then
  echo "  Waiting for 👀 reaction on kickstart comment..."
  REACTION_WAITED=0; EYES=0
  while [[ $REACTION_WAITED -lt 60 ]]; do
    EYES=$(gh api "repos/$REPO_NAME/issues/comments/$KICKSTART_ID/reactions" \
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
  echo ""
  echo "NOTE: $CONFIG_PATH on $DEFAULT_BRANCH still has integration_branch=\"$INTEGRATION_BRANCH\"."
  echo "The in-flight run needs it — do NOT revert until the final PR has opened."
  echo "Once done, revert manually, e.g.:"
  echo "  gh api repos/$REPO_NAME/contents/$CONFIG_PATH --method PUT -f message=revert -f branch=$DEFAULT_BRANCH \\"
  echo "    -f sha=\$(gh api repos/$REPO_NAME/contents/$CONFIG_PATH?ref=$DEFAULT_BRANCH --jq .sha) \\"
  echo "    -f content=\"$ORIG_CONTENT_B64\""
  trap - EXIT
  exit 0
fi

# --- Wait for the feature branch + final PR (targeting the integration branch) ---
echo "[6/7] Waiting for the final PR to open (max 30 minutes)..."
echo "  Polling every 30s..."

MAX_WAIT=1800
WAITED=0
INTERVAL=30
FEATURE_BRANCH=""
PR_NUM=""

while [[ $WAITED -lt $MAX_WAIT ]]; do
  sleep $INTERVAL
  WAITED=$((WAITED + INTERVAL))

  FINAL_PR=$(gh pr list $REPO_ARG \
    --base "$INTEGRATION_BRANCH" \
    --state all \
    --json number,state,headRefName \
    --jq "[.[] | select(.headRefName | startswith(\"feature/${FEATURE}\"))] | .[0] // empty")

  if [[ -n "$FINAL_PR" ]]; then
    PR_NUM=$(echo "$FINAL_PR" | jq -r '.number')
    PR_STATE=$(echo "$FINAL_PR" | jq -r '.state')
    FEATURE_BRANCH=$(echo "$FINAL_PR" | jq -r '.headRefName')
    echo "  Final PR #$PR_NUM found (state: $PR_STATE, branch: $FEATURE_BRANCH) after ${WAITED}s"

    if [[ "$PR_STATE" == "OPEN" || "$PR_STATE" == "MERGED" ]]; then
      break
    fi
  fi

  echo "  Still waiting... (${WAITED}s / ${MAX_WAIT}s)"
done

if [[ -z "$FEATURE_BRANCH" ]]; then
  echo ""
  echo "=== ❌ Smoke test TIMED OUT after ${MAX_WAIT}s — no final PR opened ==="
  echo "Check feature issue #$FEATURE for status."
  exit 1
fi

# --- Assertions ---
echo "[7/7] Asserting the decoupling invariant..."
PASS=true

git fetch origin "$DEFAULT_BRANCH" "$INTEGRATION_BRANCH" "$FEATURE_BRANCH" --quiet

# 1. Feature branch is rebasable onto the base (cut-point).
echo "  (1) git merge-base --is-ancestor $DEFAULT_BRANCH $FEATURE_BRANCH"
if git merge-base --is-ancestor "origin/$DEFAULT_BRANCH" "origin/$FEATURE_BRANCH"; then
  echo "      ✅ $DEFAULT_BRANCH is an ancestor of $FEATURE_BRANCH"
else
  echo "      ❌ $DEFAULT_BRANCH is NOT an ancestor of $FEATURE_BRANCH"
  PASS=false
fi

# 2. Feature PR shows only feature work (no build-only commits).
echo "  (2) git log --oneline $DEFAULT_BRANCH..$FEATURE_BRANCH"
FEATURE_LOG=$(git log --oneline "origin/$DEFAULT_BRANCH..origin/$FEATURE_BRANCH")
echo "$FEATURE_LOG" | sed 's/^/      /'
if [[ -z "$FEATURE_LOG" ]]; then
  echo "      ❌ No feature commits found on $FEATURE_BRANCH"
  PASS=false
else
  BUILD_ONLY_COUNT=$(git rev-list --count "origin/$DEFAULT_BRANCH..origin/$INTEGRATION_BRANCH")
  if [[ "$BUILD_ONLY_COUNT" -eq 0 ]]; then
    echo "      ✅ No build-only commits exist to leak into the feature branch"
  else
    echo "      ❌ $INTEGRATION_BRANCH carries $BUILD_ONLY_COUNT commit(s) ahead of $DEFAULT_BRANCH"
    PASS=false
  fi
fi

# 3. Feature PR targets the integration branch.
echo "  (3) gh pr view $PR_NUM --json baseRefName --jq .baseRefName"
PR_BASE=$(gh pr view "$PR_NUM" $REPO_ARG --json baseRefName --jq '.baseRefName')
echo "      → \"$PR_BASE\""
if [[ "$PR_BASE" == "$INTEGRATION_BRANCH" ]]; then
  echo "      ✅ PR #$PR_NUM targets \"$INTEGRATION_BRANCH\""
else
  echo "      ❌ PR #$PR_NUM targets \"$PR_BASE\", expected \"$INTEGRATION_BRANCH\""
  PASS=false
fi

# 4. The invariant: merge-base(feature, integration_branch) == base_branch tip.
echo "  (4) [ \"\$(git merge-base $FEATURE_BRANCH $INTEGRATION_BRANCH)\" = \"\$(git rev-parse $DEFAULT_BRANCH)\" ]"
MERGE_BASE=$(git merge-base "origin/$FEATURE_BRANCH" "origin/$INTEGRATION_BRANCH")
BASE_TIP=$(git rev-parse "origin/$DEFAULT_BRANCH")
if [[ "$MERGE_BASE" == "$BASE_TIP" ]]; then
  echo "      ✅ merge-base($FEATURE_BRANCH, $INTEGRATION_BRANCH) == $DEFAULT_BRANCH ($BASE_TIP)"
else
  echo "      ❌ merge-base is $MERGE_BASE, expected $DEFAULT_BRANCH tip $BASE_TIP"
  PASS=false
fi

echo ""

if [[ "$CLEANUP" == true ]]; then
  echo "Cleaning up via /quack close (also exercises the close workflow)..."

  gh pr close "$PR_NUM" $REPO_ARG --comment "Fork-mode smoke test validated — closing." 2>/dev/null || true
  gh issue comment "$FEATURE" $REPO_ARG --body "/quack close"
  echo "  /quack close triggered. Waiting for teardown..."

  CLOSE_WAITED=0; STATE=""
  while [[ $CLOSE_WAITED -lt 60 ]]; do
    STATE=$(gh issue view "$FEATURE" $REPO_ARG --json state --jq '.state' 2>/dev/null || echo "")
    if [[ "$STATE" == "CLOSED" ]]; then
      echo "  ✅ Feature issue closed (${CLOSE_WAITED}s)"
      break
    fi
    sleep 5
    CLOSE_WAITED=$((CLOSE_WAITED + 5))
  done

  if [[ "$STATE" != "CLOSED" ]]; then
    echo "  ⚠️  /quack close didn't finish within 60s — falling back to manual cleanup"
    for i in "$TASK1" "$FEATURE"; do
      gh issue close "$i" $REPO_ARG --comment "Fork-mode smoke test cleanup" 2>/dev/null || true
    done
    for b in $(gh api "repos/$REPO_NAME/git/matching-refs/heads/feature/${FEATURE}-" --jq '.[].ref | sub("refs/heads/"; "")' 2>/dev/null); do
      git push origin --delete "$b" 2>/dev/null || true
    done
  fi

  echo "  Deleting seeded \"$INTEGRATION_BRANCH\" branch..."
  gh api "repos/$REPO_NAME/git/refs/heads/$INTEGRATION_BRANCH" --method DELETE 2>/dev/null || true

  echo "Cleanup complete."
  echo ""
fi

if [[ "$PASS" == true ]]; then
  echo "=== ✅ Fork-mode smoke test PASSED ==="
  exit 0
else
  echo "=== ❌ Fork-mode smoke test FAILED ==="
  exit 1
fi
