#!/usr/bin/env bash
# =============================================================================
# Smoke Test — Update Agent
# =============================================================================
#
# PURPOSE
# -------
# Exercises a real end-to-end machinery update against a disposable scratch
# repository:
#
#   1. Provision a scratch repo and seed it with the machinery pinned to an
#      older ref (via scripts/install.sh, exactly as a real consumer would).
#   2. Apply local fixtures that a real consumer install accumulates over
#      time: an edited security-guidelines.md, a stale workflow mirror with
#      no upstream counterpart, and a hand-edited vendored machinery file.
#   3. Drive the update agent (.autoducks/agents/update/run.sh) to a newer
#      ref, using the exact env-var contract .github/workflows/autoducks-update.yml
#      invokes it with, and assert the resulting PR, lockfile and tree match
#      the documented contract (see autoducks-docs' reference/updates.mdx).
#   4. Run it again against the same target and assert no second PR opens.
#
# The update agent it drives (.autoducks/agents/update/run.sh) is implemented;
# this header previously said it did not exist, which stopped being true and
# was printed verbatim by --help.
#
# WARNING — CREATES A REAL GITHUB REPOSITORY
# -------------------------------------------
# This script runs `gh repo create` under the target owner (default: the
# authenticated `gh` user) and `gh repo delete` under --cleanup. It never
# writes to any other repository — every `gh`/`git push` call in this script
# is scoped to the scratch repo it creates for itself.
#
# USAGE
# -----
#   ./scripts/smoke-test-update.sh [OPTIONS]
#
# OPTIONS
#   --cleanup              Delete the scratch repo and local temp dirs/
#                           worktrees at the end (default: leave them for
#                           inspection).
#   --scratch-owner OWNER  GitHub owner/org to create the scratch repo under
#                           (default: the authenticated `gh` user).
#   --source-repo OWNER/REPO
#                           Repo to pull machinery from and resolve refs
#                           against (default: current repo's nameWithOwner).
#   --old-ref REF           "Before" ref to seed the scratch repo with
#                           (default: merge-base of HEAD and origin/main).
#   --new-ref REF           "After" ref to update to (default: HEAD).
#   -h, --help              Show this help.
#
# ASSERTIONS (all hard — this test has no soft/warn-only assertions)
# --------------------------------------------------------------------
#   - Exactly one PR opens on the scratch repo, titled per the update
#     contract, labeled `Autoducks:update`, with a body section reporting
#     drift.
#   - `.autoducks/.installed.json` on the PR branch has `sha`/`version`
#     matching the target ref, and `previous` carrying the pre-update triple.
#   - The locally edited `security-guidelines.md` survives untouched.
#   - The stale `.github/workflows/autoducks-ghost.yml` mirror is pruned.
#   - The locally edited vendored machinery file is replaced by the update and
#     reported in the PR body's drift section. Resolving drift is out of scope
#     by design: install.sh rewrites .autoducks/ wholesale, and on_drift "warn"
#     means proceed and say so — not preserve the edit.
#   - Running the updater again against the same target opens no second PR.
# =============================================================================

set -euo pipefail

CLEANUP=false
SCRATCH_OWNER=""
SOURCE_REPO=""
OLD_REF=""
NEW_REF=""
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cleanup) CLEANUP=true; shift ;;
    --scratch-owner) SCRATCH_OWNER="$2"; shift 2 ;;
    --source-repo) SOURCE_REPO="$2"; shift 2 ;;
    --old-ref) OLD_REF="$2"; shift 2 ;;
    --new-ref) NEW_REF="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,72p' "$0"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -z "$SOURCE_REPO" ]]; then
  SOURCE_REPO=$(cd "$SOURCE_ROOT" && gh repo view --json nameWithOwner --jq '.nameWithOwner')
fi

if [[ -z "$SCRATCH_OWNER" ]]; then
  SCRATCH_OWNER=$(gh api user --jq '.login' 2>/dev/null || echo "")
fi

if [[ -z "$OLD_REF" || -z "$NEW_REF" ]]; then
  (cd "$SOURCE_ROOT" && git fetch origin main --quiet 2>/dev/null || true)
fi
# OLD_REF must be a strict ancestor of NEW_REF, or the agent short-circuits on
# "already up to date" and the run proves nothing. The previous default,
# `git merge-base HEAD origin/main`, resolved to HEAD itself on any checkout
# level with main — i.e. every time you run this straight after landing work.
if [[ -z "$OLD_REF" ]]; then
  OLD_REF=$(cd "$SOURCE_ROOT" && git describe --tags --abbrev=0 HEAD^ 2>/dev/null || true)
fi
if [[ -z "$OLD_REF" ]]; then
  # No releases yet: any ancestor exercises the update path. Ten back if the
  # history is that long, else the root commit.
  OLD_REF=$(cd "$SOURCE_ROOT" && { git rev-parse "HEAD~10" 2>/dev/null \
              || git rev-list --max-parents=0 HEAD | head -1; })
fi
[[ -z "$NEW_REF" ]] && NEW_REF=$(cd "$SOURCE_ROOT" && git rev-parse HEAD)

OLD_RESOLVED=$(cd "$SOURCE_ROOT" && git rev-parse "$OLD_REF")
NEW_RESOLVED=$(cd "$SOURCE_ROOT" && git rev-parse "$NEW_REF")
if [[ "$OLD_RESOLVED" == "$NEW_RESOLVED" ]]; then
  echo "smoke-test-update: --old-ref and --new-ref resolve to the same commit" >&2
  echo "  ($OLD_RESOLVED). The update agent would report 'already up to date'" >&2
  echo "  and no part of the delivery path would run. Pass an older --old-ref." >&2
  exit 1
fi

SCRATCH_REPO_NAME="autoducks-smoke-update-${TIMESTAMP}"
SCRATCH_REPO="${SCRATCH_OWNER:+$SCRATCH_OWNER/}${SCRATCH_REPO_NAME}"

echo "=== Smoke Test — Update Agent ==="
echo "Source repo:  $SOURCE_REPO"
echo "Old ref:      $OLD_REF"
echo "New ref:      $NEW_REF"
echo "Scratch repo: $SCRATCH_REPO"
echo "Timestamp:    $TIMESTAMP"
echo ""

FAIL=0
WARN=0
pass() { echo "  ✅ $1"; }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }
warn() { echo "  ⚠️  $1"; WARN=$((WARN + 1)); }

WORK_DIR=$(mktemp -d)
OLD_WORKTREE="$WORK_DIR/old-ref"
NEW_WORKTREE="$WORK_DIR/new-ref"
SCRATCH_DIR="$WORK_DIR/scratch"
SCRATCH_CREATED=false

cleanup_all() {
  if [[ "$CLEANUP" != true ]]; then
    echo ""
    echo "Skipping cleanup (no --cleanup). Scratch repo: https://github.com/$SCRATCH_REPO"
    echo "Local work dir: $WORK_DIR"
    return
  fi
  echo ""
  echo "Cleaning up..."
  if [[ "$SCRATCH_CREATED" == true ]]; then
    gh repo delete "$SCRATCH_REPO" --yes 2>/dev/null || echo "  Warning: failed to delete $SCRATCH_REPO" >&2
  fi
  (cd "$SOURCE_ROOT" && git worktree remove --force "$OLD_WORKTREE" 2>/dev/null || true)
  (cd "$SOURCE_ROOT" && git worktree remove --force "$NEW_WORKTREE" 2>/dev/null || true)
  rm -rf "$WORK_DIR"
  echo "Cleanup complete."
}
trap cleanup_all EXIT

# =============================================================================
echo "[1/12] Preparing old/new-ref worktrees of $SOURCE_REPO..."
(cd "$SOURCE_ROOT" && git worktree add --detach "$OLD_WORKTREE" "$OLD_REF" --quiet)
(cd "$SOURCE_ROOT" && git worktree add --detach "$NEW_WORKTREE" "$NEW_REF" --quiet)
OLD_VERSION=$(cat "$OLD_WORKTREE/.autoducks/VERSION" 2>/dev/null || echo "")
NEW_VERSION=$(cat "$NEW_WORKTREE/.autoducks/VERSION" 2>/dev/null || echo "")
OLD_SHA=$(gh api "repos/${SOURCE_REPO}/commits/${OLD_REF}" --jq .sha 2>/dev/null || echo "")
NEW_SHA=$(gh api "repos/${SOURCE_REPO}/commits/${NEW_REF}" --jq .sha 2>/dev/null || echo "")
if [[ -z "$OLD_SHA" || -z "$NEW_SHA" ]]; then
  fail "could not resolve old/new ref to a commit on $SOURCE_REPO (old='$OLD_SHA' new='$NEW_SHA') — both refs must already be pushed"
  exit 1
fi
pass "Worktrees ready (old=$OLD_VERSION@${OLD_SHA:0:7}, new=$NEW_VERSION@${NEW_SHA:0:7})"
echo ""

echo "[2/12] Creating scratch repo $SCRATCH_REPO..."
# `gh repo create --clone` is a boolean that clones into the *current*
# directory — passing it a path makes gh parse the path as a bool and abort.
# Create, then clone explicitly to the destination we want.
gh repo create "$SCRATCH_REPO" --private >/dev/null
SCRATCH_CREATED=true
gh repo clone "$SCRATCH_REPO" "$SCRATCH_DIR" -- --quiet 2>/dev/null
pass "Scratch repo created and cloned to $SCRATCH_DIR"
echo ""

echo "[3/12] Seeding scratch repo with machinery @ $OLD_REF (old ref)..."
(
  cd "$SCRATCH_DIR"
  git checkout -B main --quiet
  AUTODUCKS_SOURCE_DIR="$OLD_WORKTREE" bash "$OLD_WORKTREE/scripts/install.sh" \
    --no-setup --source-repo "$SOURCE_REPO" --ref "$OLD_REF" \
    --lock-note "smoke-test-update seed @ ${OLD_REF}" >/dev/null
  git add -A
  git commit -q -m "smoke-test-update: seed install @ ${OLD_REF}"
  git push -q -u origin main
)
SEEDED_SHA=$(cd "$SCRATCH_DIR" && jq -r '.sha' .autoducks/.installed.json 2>/dev/null || echo "")
if [[ "$SEEDED_SHA" == "$OLD_SHA" ]]; then
  pass "Scratch repo seeded at $OLD_REF (lockfile sha=$SEEDED_SHA)"
else
  fail "seed install lockfile sha='$SEEDED_SHA', expected '$OLD_SHA'"
fi
echo ""

echo "[4/12] Ensuring 'Autoducks:update' label exists on scratch repo..."
REPO="$SCRATCH_REPO"
# shellcheck source=/dev/null
source "$SOURCE_ROOT/.autoducks/core/config/label-utils.sh"
label::ensure "Autoducks:update" "0366D6" "Pull request opened by the automatic update agent" \
  || echo "  Warning: failed to ensure label 'Autoducks:update'" >&2
pass "Label ensured"
echo ""

DRIFT_FILE=".autoducks/core/config/label-utils.sh"
DRIFT_MARKER="# smoke-test-update local customization (${TIMESTAMP})"
GHOST_WORKFLOW=".github/workflows/autoducks-ghost.yml"
SECURITY_MARKER="<!-- smoke-test-update local customization (${TIMESTAMP}) -->"

echo "[5/12] Applying local fixtures (edited security-guidelines.md, stale ghost workflow, drifted machinery file)..."
(
  cd "$SCRATCH_DIR"
  printf '\n%s\n' "$SECURITY_MARKER" >> .autoducks/security-guidelines.md
  mkdir -p .github/workflows
  cat > "$GHOST_WORKFLOW" <<EOF
name: Autoducks Ghost
on:
  workflow_dispatch: {}
jobs:
  noop:
    runs-on: ubuntu-latest
    steps:
      - run: echo "stale mirror — simulates a runtime removed upstream"
EOF
  printf '\n%s\n' "$DRIFT_MARKER" >> "$DRIFT_FILE"
  git add -A
  git commit -q -m "smoke-test-update: simulate local customization + drift"
  git push -q
)
pass "Fixtures committed and pushed"
echo ""

echo "[6/12] Capturing pre-update state..."
PRE_LOCKFILE=$(cd "$SCRATCH_DIR" && cat .autoducks/.installed.json)
PRE_DRIFT_CONTENT=$(cd "$SCRATCH_DIR" && cat "$DRIFT_FILE")
pass "Pre-update lockfile and drift-file content captured"
echo ""

echo "[7/12] Driving the update agent to $NEW_REF..."
UPDATE_LOG="$WORK_DIR/update-run-1.log"
COMMENTER=$(gh api user --jq '.login' 2>/dev/null || echo "smoke-test-update")
GH_TOKEN_VALUE=$(gh auth token 2>/dev/null || echo "")

# A machinery update always touches .github/workflows/, which the default
# GITHUB_TOKEN cannot push. The agent's Step 2 pre-flight aborts with
# `no-identity` unless AUTODUCKS_APP_TOKEN or AUTODUCKS_PAT is in its
# environment — the workflow feeds the latter from the repository secret.
# Fail here rather than 40 lines into the agent log.
if ! gh auth status 2>&1 | grep -q "workflow"; then
  echo "smoke-test-update: the authenticated gh token lacks the 'workflow' scope." >&2
  echo "  The update agent cannot push .github/workflows/ without it, so the" >&2
  echo "  delivery path this test exists to exercise would abort at Step 2." >&2
  echo "  Run: gh auth refresh -s workflow" >&2
  exit 1
fi

# drive_update_agent RUN_SUFFIX LOGFILE → run the agent exactly as
# autoducks-update.yml does, returning its exit code.
#
# The workflow declares REF/MODE/DRY_RUN/REPO/RUN_ID/COMMENTER/GH_TOKEN and
# inherits the rest from the runner. Reproducing only the declared half is not
# the workflow's contract: providers/llm/claude/resolve-endpoint.sh aborts with
# "GITHUB_OUTPUT must be set" before the agent does anything, so every run
# failed at step 7 with no PR and steps 8-10 fell over behind it.
drive_update_agent() {
  local suffix="$1" logfile="$2" rc=0
  local out="$WORK_DIR/github-output-$suffix.txt"
  local env_file="$WORK_DIR/github-env-$suffix.txt"
  local summary="$WORK_DIR/github-step-summary-$suffix.md"
  : > "$out"; : > "$env_file"; : > "$summary"
  (
    cd "$SCRATCH_DIR"
    REF="$NEW_REF" MODE="pr" DRY_RUN="false" REPO="$SCRATCH_REPO" \
    RUN_ID="smoke-${TIMESTAMP}-${suffix}" COMMENTER="$COMMENTER" GH_TOKEN="$GH_TOKEN_VALUE" \
    AUTODUCKS_PAT="$GH_TOKEN_VALUE" \
    GITHUB_ACTIONS="true" GITHUB_OUTPUT="$out" GITHUB_ENV="$env_file" \
    GITHUB_STEP_SUMMARY="$summary" GITHUB_WORKSPACE="$SCRATCH_DIR" \
      bash "$NEW_WORKTREE/.autoducks/agents/update/run.sh"
  ) > "$logfile" 2>&1 || rc=$?
  return "$rc"
}

UPDATE_RC=0
drive_update_agent 1 "$UPDATE_LOG" || UPDATE_RC=$?

if [[ $UPDATE_RC -eq 0 ]]; then
  pass "update agent run completed (see $UPDATE_LOG)"
else
  fail "update agent run failed (rc=$UPDATE_RC) — see $UPDATE_LOG"
  echo "  --- last 20 lines of $UPDATE_LOG ---"
  tail -n 20 "$UPDATE_LOG" | sed 's/^/  | /'
fi
echo ""

echo "[8/12] Asserting the update PR exists with expected title/label/body..."
PRS_JSON=$(gh pr list --repo "$SCRATCH_REPO" --state all \
  --json number,title,labels,body,headRefName 2>/dev/null || echo "[]")
PR_COUNT=$(echo "$PRS_JSON" | jq 'length')
if [[ "$PR_COUNT" -eq 1 ]]; then
  pass "Exactly one PR opened on $SCRATCH_REPO"
  PR_NUMBER=$(echo "$PRS_JSON" | jq -r '.[0].number')
  PR_TITLE=$(echo "$PRS_JSON" | jq -r '.[0].title')
  PR_LABELS=$(echo "$PRS_JSON" | jq -r '[.[0].labels[].name] | join(",")')
  PR_BODY=$(echo "$PRS_JSON" | jq -r '.[0].body')
  PR_BRANCH=$(echo "$PRS_JSON" | jq -r '.[0].headRefName')

  if [[ "$PR_TITLE" == *"${NEW_VERSION}"* || "$PR_TITLE" == *"${NEW_SHA:0:7}"* ]]; then
    pass "PR #$PR_NUMBER title references the target (title: \"$PR_TITLE\")"
  else
    fail "PR #$PR_NUMBER title does not reference target version/sha (title: \"$PR_TITLE\", expected to contain '$NEW_VERSION' or '${NEW_SHA:0:7}')"
  fi

  if echo "$PR_LABELS" | grep -q "Autoducks:update"; then
    pass "PR #$PR_NUMBER labeled Autoducks:update"
  else
    fail "PR #$PR_NUMBER missing label Autoducks:update (labels: ${PR_LABELS:-none})"
  fi

  # The heading is emitted verbatim by update::pr_body (run.sh:464) and does not
  # contain the word "drift" — the previous `^#+ .*drift` pattern could never
  # match, so this assertion failed against a PR body that was in fact correct.
  if echo "$PR_BODY" | grep -qF '## ⚠️ Local machinery changes overwritten'; then
    pass "PR #$PR_NUMBER body has a drift section"
  else
    fail "PR #$PR_NUMBER body has no drift section (observed body:\n$PR_BODY)"
  fi
else
  fail "expected exactly 1 PR on $SCRATCH_REPO, found $PR_COUNT"
  PR_NUMBER=""
  PR_BRANCH=""
fi
echo ""

echo "[9/12] Asserting the lockfile moved to the target..."
if [[ -n "$PR_BRANCH" ]]; then
  (cd "$SCRATCH_DIR" && git fetch origin "$PR_BRANCH" --quiet 2>/dev/null || true)
  POST_LOCKFILE=$(cd "$SCRATCH_DIR" && git show "origin/${PR_BRANCH}:.autoducks/.installed.json" 2>/dev/null || echo "")
  if [[ -z "$POST_LOCKFILE" ]]; then
    fail "could not read .autoducks/.installed.json from origin/$PR_BRANCH"
  else
    POST_SHA=$(echo "$POST_LOCKFILE" | jq -r '.sha')
    POST_VERSION=$(echo "$POST_LOCKFILE" | jq -r '.version')
    PREV_SHA=$(echo "$POST_LOCKFILE" | jq -r '.previous.sha // ""')
    PREV_VERSION=$(echo "$POST_LOCKFILE" | jq -r '.previous.version // ""')

    [[ "$POST_SHA" == "$NEW_SHA" ]] \
      && pass "lockfile sha=$POST_SHA matches target" \
      || fail "lockfile sha='$POST_SHA', expected target '$NEW_SHA'"

    [[ "$POST_VERSION" == "$NEW_VERSION" ]] \
      && pass "lockfile version=$POST_VERSION matches target" \
      || fail "lockfile version='$POST_VERSION', expected target '$NEW_VERSION'"

    [[ "$PREV_SHA" == "$OLD_SHA" && "$PREV_VERSION" == "$OLD_VERSION" ]] \
      && pass "lockfile previous={sha:$PREV_SHA, version:$PREV_VERSION} carries the pre-update triple" \
      || fail "lockfile previous={sha:'$PREV_SHA', version:'$PREV_VERSION'}, expected {sha:'$OLD_SHA', version:'$OLD_VERSION'}"
  fi
else
  fail "no PR branch to inspect — skipping lockfile assertions"
fi
echo ""

echo "[10/12] Asserting preservation/pruning/drift-reporting on the PR branch..."
if [[ -n "$PR_BRANCH" ]]; then
  POST_SECURITY=$(cd "$SCRATCH_DIR" && git show "origin/${PR_BRANCH}:.autoducks/security-guidelines.md" 2>/dev/null || echo "")
  if echo "$POST_SECURITY" | grep -qF "$SECURITY_MARKER"; then
    pass "edited security-guidelines.md survived the update"
  else
    fail "security-guidelines.md local edit did not survive (marker '$SECURITY_MARKER' not found)"
  fi

  if (cd "$SCRATCH_DIR" && git cat-file -e "origin/${PR_BRANCH}:${GHOST_WORKFLOW}" 2>/dev/null); then
    fail "stale $GHOST_WORKFLOW was not pruned"
  else
    pass "stale $GHOST_WORKFLOW was pruned"
  fi

  # The design puts "resolving local machinery drift" out of scope: the updater
  # detects and reports it, never merges it. install.sh replaces .autoducks/
  # wholesale, so a locally edited machinery file IS overwritten — and the
  # contract is that the PR body says so, which the next assertion checks.
  #
  # Asserting preservation here demanded the opposite of the delivered design,
  # so this test could never pass against a correct implementation. What is
  # worth pinning is that the overwrite is not silent.
  POST_DRIFT_CONTENT=$(cd "$SCRATCH_DIR" && git show "origin/${PR_BRANCH}:${DRIFT_FILE}" 2>/dev/null || echo "")
  if echo "$POST_DRIFT_CONTENT" | grep -qF "$DRIFT_MARKER"; then
    fail "locally edited $DRIFT_FILE still carries '$DRIFT_MARKER' — the update did not replace the machinery file as install.sh is specified to"
  else
    pass "locally edited $DRIFT_FILE was replaced by the update, as designed (reporting is asserted next)"
  fi

  # update::drift_section (run.sh:400-407) lists paths relative to .autoducks/,
  # because that is the tree drift is detected inside. Asserting on the
  # repo-relative form failed against a body that named the file correctly.
  DRIFT_FILE_REPORTED="${DRIFT_FILE#.autoducks/}"
  if echo "$PR_BODY" | grep -qF "$DRIFT_FILE_REPORTED"; then
    pass "PR body's drift section names $DRIFT_FILE_REPORTED"
  else
    fail "PR body does not mention $DRIFT_FILE_REPORTED in its drift section (observed body:\n$PR_BODY)"
  fi
else
  fail "no PR branch to inspect — skipping preservation/drift assertions"
fi
echo ""

echo "[11/12] Re-running the updater against the same target..."
UPDATE_LOG_2="$WORK_DIR/update-run-2.log"
UPDATE_RC_2=0
drive_update_agent 2 "$UPDATE_LOG_2" || UPDATE_RC_2=$?

PRS_JSON_2=$(gh pr list --repo "$SCRATCH_REPO" --state all --json number 2>/dev/null || echo "[]")
PR_COUNT_2=$(echo "$PRS_JSON_2" | jq 'length')
if [[ "$PR_COUNT_2" -eq "$PR_COUNT" ]]; then
  pass "second update run opened no additional PR (still $PR_COUNT_2 total)"
else
  fail "second update run changed PR count: was $PR_COUNT, now $PR_COUNT_2 (rc=$UPDATE_RC_2, see $UPDATE_LOG_2)"
fi
echo ""

echo "[12/12] Done."
echo ""

# --- Summary ---
echo "=== Summary ==="
echo "  Fail:    $FAIL"
echo "  Warn:    $WARN"

if [[ $FAIL -eq 0 ]]; then
  if [[ $WARN -eq 0 ]]; then
    echo "✅ Update-agent smoke test passed with no warnings."
  else
    echo "✅ Update-agent smoke test passed with $WARN soft warning(s)."
  fi
  exit 0
else
  echo "❌ Update-agent smoke test FAILED — $FAIL hard assertion(s) violated."
  exit 1
fi
