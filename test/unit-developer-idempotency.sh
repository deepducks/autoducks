#!/usr/bin/env bash
# Developer idempotency test — locks two invariants of
# `.autoducks/agents/developer/pre.sh`:
#
#   1. The pre-existing union open+merged PR guard: any task whose PR
#      already exists (open OR merged) trips `duplicate_skip=true` and exits
#      0 before a branch is ever cut.
#   2. T1's branch-aware resume: with no claiming PR, a task that already
#      has a preserved `…-issue-<t>-…` remote branch (e.g. left behind by a
#      max_turns cutoff) checks that branch back out instead of cutting a
#      fresh `-<epoch>` branch; only when neither a PR nor a branch exists
#      does pre.sh fall back to cutting a fresh branch from base.
#
# Runs the real developer/pre.sh as a subprocess with `gh` shimmed out (same
# technique as test/unit-idempotency.sh) plus a throwaway local git repo so
# the checkout/branch-cut logic can run for real without touching this repo.
#
# Run: bash test/unit-developer-idempotency.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

REPO_NAME="acme/widgets"
GH_LOG="$SCRATCH/gh.log"
: > "$GH_LOG"
MOCK_ISSUE_DIR="$SCRATCH/issues"
GH_CAPTURE_DIR="$SCRATCH/captured"
mkdir -p "$MOCK_ISSUE_DIR" "$GH_CAPTURE_DIR"

# ── Throwaway local git repo ──────────────────────────────────────────
# pre.sh's branch resume/cut logic runs real `git checkout`/`git checkout -b`
# against whatever is cwd. Give it its own repo so the real project working
# tree is never touched.
GIT_SCRATCH="$SCRATCH/repo"
mkdir -p "$GIT_SCRATCH"
git -C "$GIT_SCRATCH" init -q -b main
git -C "$GIT_SCRATCH" config user.email "test@example.com"
git -C "$GIT_SCRATCH" config user.name "Test"
echo "seed" > "$GIT_SCRATCH/README.md"
git -C "$GIT_SCRATCH" add README.md
git -C "$GIT_SCRATCH" commit -q -m "seed"
git -C "$GIT_SCRATCH" branch feature/99-widget

# A branch preserved from a previous (e.g. max_turns-truncated) run of task
# #20 — fixture for the T1 resume assertion.
RESUME_BRANCH="feature/99-issue-20-1700000000"
git -C "$GIT_SCRATCH" checkout -q -b "$RESUME_BRANCH"
echo "wip from a previous run" >> "$GIT_SCRATCH/README.md"
git -C "$GIT_SCRATCH" commit -q -am "WIP prior run"
git -C "$GIT_SCRATCH" checkout -q main

# ── Shared gh shim ────────────────────────────────────────────────────
# developer/pre.sh reaches the outside world only through its::*/git::*
# provider functions, which all bottom out in `gh`. Putting a fake `gh`
# first on PATH lets the real pre.sh run unmodified against canned fixtures
# instead of hitting GitHub.
mkdir -p "$SCRATCH/bin"
cat > "$SCRATCH/bin/gh" <<'SHIM'
#!/usr/bin/env bash
{
  echo "=== gh $* ==="
} >> "$GH_LOG"

case "$1" in
  issue)
    case "$2" in
      view)
        id="$3"
        if [[ -f "$MOCK_ISSUE_DIR/$id.json" ]]; then
          cat "$MOCK_ISSUE_DIR/$id.json"
        else
          echo '{}'
        fi
        ;;
      comment)
        echo "https://github.com/x/y/issues/$3#issuecomment-777"
        ;;
      edit) : ;;
      close) : ;;
    esac
    ;;
  label)
    : # label create
    ;;
  pr)
    case "$2" in
      list)
        state="open"
        prev=""
        for arg in "$@"; do
          [[ "$prev" == "--state" ]] && state="$arg"
          prev="$arg"
        done
        case "$state" in
          open)   cat "${MOCK_OPEN_PRS_FILE:-/dev/null}" 2>/dev/null || echo "[]" ;;
          merged) cat "${MOCK_MERGED_PRS_FILE:-/dev/null}" 2>/dev/null || echo "[]" ;;
          *)      echo "[]" ;;
        esac
        ;;
    esac
    ;;
  api)
    method="GET"
    path=""
    prevflag=""
    for arg in "${@:2}"; do
      if [[ "$prevflag" == "--method" ]]; then
        method="$arg"; prevflag=""; continue
      fi
      case "$arg" in
        --method) prevflag="--method"; continue ;;
        --*)      continue ;;
        *)        [[ -z "$path" ]] && path="$arg" ;;
      esac
    done
    if [[ "$path" == */git/matching-refs/heads/* ]]; then
      # Emulate `--jq '.[].ref | sub("^refs/heads/"; "")'` server-side: only
      # ever return the one fixture branch, and only for the prefix pattern
      # it actually matches (git::find_branches_matching probes both the
      # feature/ and fix/ prefix per D10, one of which is a dead end).
      ref_pattern="${path#*/git/matching-refs/heads/}"
      if [[ -n "${MOCK_MATCHING_BRANCH:-}" && "$MOCK_MATCHING_BRANCH" == "$ref_pattern"* ]]; then
        echo "$MOCK_MATCHING_BRANCH"
      fi
    elif [[ "$path" == */git/refs/heads/* ]]; then
      : # branch-exists probe (wait_for_branch) — always succeeds immediately
    else
      :
    fi
    ;;
  *) : ;;
esac
exit 0
SHIM
chmod +x "$SCRATCH/bin/gh"

# run_step <script> [KEY=VAL ...]
# Runs developer/pre.sh as a real subprocess (its own `set -e`, its own ERR
# trap), cwd'd into the throwaway git repo, with the shim first on PATH.
# Prints stderr and returns the script's exit code so callers can assert on it.
run_step() {
  local script="$1"; shift
  local rc=0
  ( cd "$GIT_SCRATCH" && env "$@" \
      PATH="$SCRATCH/bin:$PATH" \
      GH_LOG="$GH_LOG" \
      MOCK_ISSUE_DIR="$MOCK_ISSUE_DIR" \
      MOCK_OPEN_PRS_FILE="${MOCK_OPEN_PRS_FILE:-}" \
      MOCK_MERGED_PRS_FILE="${MOCK_MERGED_PRS_FILE:-}" \
      MOCK_MATCHING_BRANCH="${MOCK_MATCHING_BRANCH:-}" \
      GH_CAPTURE_DIR="$GH_CAPTURE_DIR" \
      GITHUB_ACTIONS=true \
      GH_TOKEN=t \
      REPO="$REPO_NAME" \
      bash "$script" > "$SCRATCH/stdout.log" 2> "$SCRATCH/stderr.log" ) || rc=$?
  return $rc
}

DEVELOPER_PRE="$REPO_ROOT/.autoducks/agents/developer/pre.sh"
BASE_BRANCH_D="feature/99-widget"

fixture_issue() {
  local num="$1"
  jq -n --arg t "$num" '{title: ("Task #" + $t), body: "Implement the thing.", labels: [], author: "bob"}' \
    > "$MOCK_ISSUE_DIR/$num.json"
}

reset_run() {
  rm -f /tmp/autoducks-pre-failed /tmp/autoducks-dor-delegated /tmp/autoducks-status-comment-id /tmp/task-spec.md
  : > "$GH_LOG"
}

current_branch() { git -C "$GIT_SCRATCH" rev-parse --abbrev-ref HEAD; }

run_developer() {
  local task="$1" out_file="$2"
  : > "$out_file"
  run_step "$DEVELOPER_PRE" ISSUE_NUM="$task" RUN_ID=1 COMMENT_ID=1 COMMENTER=bob \
    BASE_BRANCH="$BASE_BRANCH_D" GITHUB_OUTPUT="$out_file"
}

# =============================================================================
# 1. An open PR claiming the task → duplicate_skip=true, no branch cut
# =============================================================================
echo "── Developer: open PR claiming the task trips duplicate-skip ──"

TASK_OPEN=10
fixture_issue "$TASK_OPEN"
MOCK_OPEN_PRS_FILE="$SCRATCH/open_prs_open.json"
MOCK_MERGED_PRS_FILE="$SCRATCH/merged_prs_empty.json"
MOCK_MATCHING_BRANCH=""
jq -n --arg body "Implements the thing.

Fixes #$TASK_OPEN" \
  '[{number: 601, title: "Task 10 in flight", headRefName: "feature/99-widget/task/10-thing", body: $body}]' \
  > "$MOCK_OPEN_PRS_FILE"
echo '[]' > "$MOCK_MERGED_PRS_FILE"

reset_run
BRANCH_BEFORE=$(current_branch)
RC=0
run_developer "$TASK_OPEN" "$SCRATCH/out_open.txt" || RC=$?
[[ "$RC" -eq 0 ]] \
  && pass "open-PR guard: pre.sh exits 0" \
  || fail "open-PR guard: rc=$RC: $(tail -5 "$SCRATCH/stderr.log")"
grep -q '^duplicate_skip=true$' "$SCRATCH/out_open.txt" \
  && pass "open-PR guard: duplicate_skip=true emitted" \
  || fail "open-PR guard: duplicate_skip=true missing, got: $(cat "$SCRATCH/out_open.txt")"
[[ "$(current_branch)" == "$BRANCH_BEFORE" ]] \
  && pass "open-PR guard: no branch cut (still on $BRANCH_BEFORE)" \
  || fail "open-PR guard: branch changed from $BRANCH_BEFORE to $(current_branch) — a branch was cut despite the guard"

echo ""

# =============================================================================
# 2. A merged PR claiming the task → duplicate_skip=true, no branch cut
# =============================================================================
echo "── Developer: merged PR claiming the task trips duplicate-skip ──"

TASK_MERGED=11
fixture_issue "$TASK_MERGED"
MOCK_OPEN_PRS_FILE="$SCRATCH/open_prs_empty.json"
MOCK_MERGED_PRS_FILE="$SCRATCH/merged_prs_merged.json"
MOCK_MATCHING_BRANCH=""
echo '[]' > "$MOCK_OPEN_PRS_FILE"
jq -n --arg body "Implements the thing.

Fixes #$TASK_MERGED" \
  '[{number: 602, title: "Task 11 done", headRefName: "feature/99-widget/task/11-thing", body: $body}]' \
  > "$MOCK_MERGED_PRS_FILE"

reset_run
BRANCH_BEFORE=$(current_branch)
RC=0
run_developer "$TASK_MERGED" "$SCRATCH/out_merged.txt" || RC=$?
[[ "$RC" -eq 0 ]] \
  && pass "merged-PR guard: pre.sh exits 0" \
  || fail "merged-PR guard: rc=$RC: $(tail -5 "$SCRATCH/stderr.log")"
grep -q '^duplicate_skip=true$' "$SCRATCH/out_merged.txt" \
  && pass "merged-PR guard: duplicate_skip=true emitted" \
  || fail "merged-PR guard: duplicate_skip=true missing, got: $(cat "$SCRATCH/out_merged.txt")"
[[ "$(current_branch)" == "$BRANCH_BEFORE" ]] \
  && pass "merged-PR guard: no branch cut (still on $BRANCH_BEFORE)" \
  || fail "merged-PR guard: branch changed from $BRANCH_BEFORE to $(current_branch) — a branch was cut despite the guard"

echo ""

# =============================================================================
# 3. T1 — no claiming PR, but an existing `…-issue-<t>-…` branch → resume it
# =============================================================================
echo "── Developer (T1): no PR + existing branch → resumes it instead of cutting fresh ──"

TASK_RESUME=20
fixture_issue "$TASK_RESUME"
MOCK_OPEN_PRS_FILE="$SCRATCH/open_prs_empty2.json"
MOCK_MERGED_PRS_FILE="$SCRATCH/merged_prs_empty2.json"
MOCK_MATCHING_BRANCH="$RESUME_BRANCH"
echo '[]' > "$MOCK_OPEN_PRS_FILE"
echo '[]' > "$MOCK_MERGED_PRS_FILE"

reset_run
RC=0
run_developer "$TASK_RESUME" "$SCRATCH/out_resume.txt" || RC=$?
[[ "$RC" -eq 0 ]] \
  && pass "resume: pre.sh exits 0" \
  || fail "resume: rc=$RC: $(tail -5 "$SCRATCH/stderr.log")"
if grep -q '^duplicate_skip=true$' "$SCRATCH/out_resume.txt" 2>/dev/null; then
  fail "resume: duplicate_skip fired even though no PR claims task #$TASK_RESUME"
else
  pass "resume: duplicate_skip did not fire (no claiming PR)"
fi
[[ "$(current_branch)" == "$RESUME_BRANCH" ]] \
  && pass "resume: checked out the preserved branch $RESUME_BRANCH instead of cutting a fresh one" \
  || fail "resume: expected HEAD on $RESUME_BRANCH, got $(current_branch)"
grep -q "::notice::Resuming preserved branch $RESUME_BRANCH " "$SCRATCH/stdout.log" "$SCRATCH/stderr.log" 2>/dev/null \
  && pass "resume: notice/status mentions resuming the preserved branch" \
  || fail "resume: no resume notice found for $RESUME_BRANCH"

echo ""

# =============================================================================
# 4. No PR and no existing branch → a fresh task branch is cut from base
# =============================================================================
echo "── Developer: no PR + no existing branch → cuts a fresh branch from base ──"

TASK_FRESH=30
fixture_issue "$TASK_FRESH"
MOCK_OPEN_PRS_FILE="$SCRATCH/open_prs_empty3.json"
MOCK_MERGED_PRS_FILE="$SCRATCH/merged_prs_empty3.json"
MOCK_MATCHING_BRANCH=""   # no branch matches feature/99-issue-30- or fix/99-issue-30-
echo '[]' > "$MOCK_OPEN_PRS_FILE"
echo '[]' > "$MOCK_MERGED_PRS_FILE"

reset_run
git -C "$GIT_SCRATCH" checkout -q main
RC=0
run_developer "$TASK_FRESH" "$SCRATCH/out_fresh.txt" || RC=$?
[[ "$RC" -eq 0 ]] \
  && pass "fresh cut: pre.sh exits 0" \
  || fail "fresh cut: rc=$RC: $(tail -5 "$SCRATCH/stderr.log")"
if grep -q '^duplicate_skip=true$' "$SCRATCH/out_fresh.txt" 2>/dev/null; then
  fail "fresh cut: duplicate_skip fired even though no PR claims task #$TASK_FRESH"
else
  pass "fresh cut: duplicate_skip did not fire (no claiming PR)"
fi
NEW_BRANCH="$(current_branch)"
if [[ "$NEW_BRANCH" =~ ^(feature|fix)/99-issue-30-[0-9]+$ ]]; then
  pass "fresh cut: a fresh task branch matching …-issue-30-<epoch> was cut ($NEW_BRANCH)"
else
  fail "fresh cut: expected a fresh …-issue-30-<epoch> branch, got $NEW_BRANCH"
fi
[[ "$NEW_BRANCH" != "$RESUME_BRANCH" ]] \
  && pass "fresh cut: did not resume the unrelated preserved branch from task #20" \
  || fail "fresh cut: incorrectly resumed $RESUME_BRANCH"
if grep -q '::notice::Resuming preserved branch' "$SCRATCH/stdout.log" "$SCRATCH/stderr.log" 2>/dev/null; then
  fail "fresh cut: resume notice unexpectedly present when no branch should have been found"
else
  pass "fresh cut: no resume notice (correctly took the fresh-cut path)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "═══ developer idempotency: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
