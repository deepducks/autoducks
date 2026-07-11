#!/usr/bin/env bash
# post.sh-level test for the Developer's reworked completion flow
# (.autoducks/agents/developer/post.sh):
#
#   Fix 1 — the explicit `its::close_issue` never closes a feature issue
#   (guarded on ISSUE_NUM != FEATURE_NUM); a real sub-task is still closed.
#   Fix 2d — the `git::commits_ahead` / no-code-artifact three-way decision
#   branch, inserted before `git::create_pr`: a non-empty diff always wins
#   and creates a PR; an empty diff with a recorded artifact is a legitimate
#   no-op (comment + close + Maestro re-dispatch, no PR, no failure); an
#   empty diff with no artifact fails via the existing `assert_changes` path.
#
# Runs the real developer/post.sh as a subprocess against a throwaway local
# git repo with a real (local, bare) "origin" remote, so `git push`/`git
# fetch` — and therefore `git::commits_ahead` — run for real with no network.
# `gh` is shimmed the same way as test/unit-developer-idempotency.sh.
#
# assert-changes.sh's base-relative rewrite is owned by a sibling task (#965)
# and lands independently, so this test runs post.sh against a scratch
# AUTODUCKS_ROOT overlay — an exact copy of .autoducks with assert-changes.sh
# replaced by that sibling task's target contract (`assert_changes <base>`,
# gated on `git::commits_ahead`). This isolates the post.sh routing logic
# under test from that (separately-tested) file.
#
# Run: bash test/unit-developer-post-decision-branch.sh
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
mkdir -p "$MOCK_ISSUE_DIR"

# ── Scratch AUTODUCKS_ROOT: real .autoducks, with assert-changes.sh swapped
# for #965's target (base-relative) contract ──────────────────────────────
AUTODUCKS_SCRATCH_ROOT="$SCRATCH/autoducks-root"
cp -r "$REPO_ROOT/.autoducks" "$AUTODUCKS_SCRATCH_ROOT"
cat > "$AUTODUCKS_SCRATCH_ROOT/core/robustness/assert-changes.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
assert_changes() {
  local base="$1"
  git add -A
  if git diff --cached --quiet; then
    if [[ "$(git::commits_ahead "$base")" -gt 0 ]]; then
      echo "::warning::No newly-staged changes, but this branch is ahead of base"
      return 0
    fi
    echo "::error::Agent made no changes to the codebase"
    return 1
  fi
  return 0
}
EOF

# ── Throwaway local git repo + a real (local, bare) origin ────────────────
# post.sh's push/fetch (git::push_branch, git::commits_ahead, the merge-retry
# loop) run as real `git` commands against whatever "origin" resolves to.
# A local bare repo lets all of that run for real with no network — as long
# as GH_TOKEN/GITHUB_TOKEN stay unset, git::push_branch never rewrites
# origin's URL to a (fake) github.com remote.
ORIGIN_BARE="$SCRATCH/origin.git"
git init -q --bare -b main "$ORIGIN_BARE"

GIT_SCRATCH="$SCRATCH/repo"
mkdir -p "$GIT_SCRATCH"
git -C "$GIT_SCRATCH" init -q -b main
git -C "$GIT_SCRATCH" config user.email "test@example.com"
git -C "$GIT_SCRATCH" config user.name "Test"
git -C "$GIT_SCRATCH" remote add origin "$ORIGIN_BARE"
echo "seed" > "$GIT_SCRATCH/README.md"
git -C "$GIT_SCRATCH" add README.md
git -C "$GIT_SCRATCH" commit -q -m "seed"
git -C "$GIT_SCRATCH" push -q -u origin main

FEATURE_BRANCH="feature/99-widget"
git -C "$GIT_SCRATCH" checkout -q -b "$FEATURE_BRANCH"
git -C "$GIT_SCRATCH" push -q -u origin "$FEATURE_BRANCH"
git -C "$GIT_SCRATCH" checkout -q main

# ── Shared gh shim ──────────────────────────────────────────────────────
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
          echo '{"title":"Task","body":"","labels":[],"author":"bob"}'
        fi
        ;;
      comment) echo "https://github.com/x/y/issues/$3#issuecomment-777" ;;
      close)   : ;;
      edit)    : ;;
    esac
    ;;
  label)
    : # label create
    ;;
  pr)
    case "$2" in
      create)
        n=$(( $(cat "$SCRATCH/pr_seq" 2>/dev/null || echo 500) + 1 ))
        echo "$n" > "$SCRATCH/pr_seq"
        echo "https://github.com/x/y/pull/$n"
        ;;
      edit)  : ;;
      merge) exit "${MOCK_MERGE_RC:-0}" ;;
      list)  echo "[]" ;;
    esac
    ;;
  workflow)
    case "$2" in
      run) : ;;
    esac
    ;;
  api)
    : # reactions POST, comment PATCH, repo-settings GET (unused: merge_method=merge below)
    ;;
  *) : ;;
esac
exit 0
SHIM
chmod +x "$SCRATCH/bin/gh"

# run_post ISSUE_NUM BASE_BRANCH → runs the real post.sh as a subprocess,
# cwd'd on whatever branch is currently checked out in $GIT_SCRATCH.
# Prints stderr/stdout to scratch logs and returns post.sh's exit code.
run_post() {
  local issue_num="$1" base_branch="$2"
  local rc=0
  ( cd "$GIT_SCRATCH" && env -u GH_TOKEN -u GITHUB_TOKEN \
      PATH="$SCRATCH/bin:$PATH" \
      GH_LOG="$GH_LOG" \
      MOCK_ISSUE_DIR="$MOCK_ISSUE_DIR" \
      SCRATCH="$SCRATCH" \
      AUTODUCKS_ROOT="$AUTODUCKS_SCRATCH_ROOT" \
      AUTODUCKS_MERGE_METHOD="merge" \
      GITHUB_ACTIONS=true \
      REPO="$REPO_NAME" \
      RUN_ID=9001 COMMENT_ID=5551 COMMENTER=alice \
      MODEL=test-model EFFORT=test-effort \
      ISSUE_NUM="$issue_num" BASE_BRANCH="$base_branch" \
      bash "$REPO_ROOT/.autoducks/agents/developer/post.sh" \
      > "$SCRATCH/stdout.log" 2> "$SCRATCH/stderr.log" ) || rc=$?
  return $rc
}

fixture_issue() {
  local num="$1" title="$2"
  jq -n --arg t "$title" '{title: $t, body: "Implement the thing.", labels: [], author: "bob"}' \
    > "$MOCK_ISSUE_DIR/$num.json"
}

reset_state() {
  : > "$GH_LOG"
  rm -f /tmp/no-code-result.md /tmp/work-summary.md /tmp/task-spec.md \
        /tmp/autoducks-pre-failed /tmp/autoducks-dor-delegated \
        /tmp/autoducks-status-comment-id.*
}

# new_task_branch NAME → cut a fresh branch from the feature branch (local
# only — mirrors pre.sh's cut-from-base, but not pushed: post.sh pushes it
# itself on the diff path).
new_task_branch() {
  local name="$1"
  git -C "$GIT_SCRATCH" checkout -q "$FEATURE_BRANCH"
  git -C "$GIT_SCRATCH" checkout -q -b "$name"
}

make_diff() {
  echo "agent change $RANDOM" >> "$GIT_SCRATCH/README.md"
}

echo ""

# =============================================================================
# 1. Real sub-task (ISSUE_NUM != FEATURE_NUM) with a diff → PR created,
#    merged, sub-task closed (scenario 5); feature issue never touched.
# =============================================================================
echo "── Real sub-task + diff: PR created/merged, sub-task closed (Fix 1 unaffected) ──"

TASK=101
fixture_issue "$TASK" "Sub-task 101"
reset_state
new_task_branch "feature/99-issue-$TASK-a"
make_diff

RC=0
run_post "$TASK" "$FEATURE_BRANCH" || RC=$?
[[ "$RC" -eq 0 ]] && pass "exits 0" || fail "rc=$RC: $(tail -5 "$SCRATCH/stderr.log")"
grep -q '^=== gh pr create ' "$GH_LOG" && pass "PR created" || fail "no gh pr create: $(cat "$GH_LOG")"
grep -q '^=== gh pr merge ' "$GH_LOG" && pass "PR merged" || fail "no gh pr merge: $(cat "$GH_LOG")"
grep -qE "gh issue close $TASK .*--reason completed" "$GH_LOG" \
  && pass "sub-task #$TASK closed completed" \
  || fail "sub-task #$TASK not closed: $(cat "$GH_LOG")"
if grep -qE "gh issue close 99 " "$GH_LOG"; then
  fail "feature issue #99 was closed by the sub-task run"
else
  pass "feature issue #99 was not closed"
fi
if grep -q '^=== gh workflow run autoducks-maestro.yml' "$GH_LOG"; then
  fail "Maestro was explicitly re-dispatched on a normal PR-merge path (should ride the merge event only)"
else
  pass "no explicit Maestro re-dispatch on the normal path"
fi
grep -qF "Maestro drives the feature to completion" "$GH_LOG" \
  && pass "completion comment uses the real-sub-task arm" \
  || fail "real-sub-task completion arm text not found"

echo ""

# =============================================================================
# 2. Single-task run (ISSUE_NUM == FEATURE_NUM) with a diff → PR
#    created/merged, but the feature issue is NOT closed (scenario 1); the
#    completion comment points at the draft delivery PR.
# =============================================================================
echo "── Single-task (ISSUE_NUM == FEATURE_NUM) + diff: feature not closed ──"

fixture_issue 99 "Widget feature"
reset_state
new_task_branch "feature/99-issue-99-a"
make_diff

RC=0
run_post 99 "$FEATURE_BRANCH" || RC=$?
[[ "$RC" -eq 0 ]] && pass "exits 0" || fail "rc=$RC: $(tail -5 "$SCRATCH/stderr.log")"
grep -q '^=== gh pr create ' "$GH_LOG" && pass "PR created" || fail "no gh pr create: $(cat "$GH_LOG")"
grep -q '^=== gh pr merge ' "$GH_LOG" && pass "PR merged" || fail "no gh pr merge: $(cat "$GH_LOG")"
if grep -qE "gh issue close 99 " "$GH_LOG"; then
  fail "feature issue #99 was closed in single-task mode (Fix 1 guard did not fire)"
else
  pass "feature issue #99 was NOT closed (Fix 1 guard held)"
fi
grep -qF "draft delivery PR" "$GH_LOG" \
  && pass "completion comment points at the draft delivery PR" \
  || fail "single-task completion arm text not found"
grep -qF "the feature closes only when you merge it" "$GH_LOG" \
  && pass "completion comment says the feature closes only on human review/merge" \
  || fail "single-task completion arm missing the awaits-review phrasing"

echo ""

# =============================================================================
# 3. Empty diff + no-code artifact, real sub-task → legitimate no-op:
#    comment + close, no PR, Maestro re-dispatched, no failure (scenario 2).
# =============================================================================
echo "── Empty diff + artifact: no-op completion (comment, close, dispatch, no PR) ──"

TASK=102
fixture_issue "$TASK" "Verification-only task"
reset_state
new_task_branch "feature/99-issue-$TASK-a"
echo "Verified: no code changes needed." > /tmp/no-code-result.md

RC=0
run_post "$TASK" "$FEATURE_BRANCH" || RC=$?
[[ "$RC" -eq 0 ]] && pass "exits 0 (no failure on the legitimate no-op)" || fail "rc=$RC: $(tail -5 "$SCRATCH/stderr.log")"
if grep -q '^=== gh pr create ' "$GH_LOG"; then
  fail "a PR was created on the no-op path"
else
  pass "no PR created"
fi
grep -qF "Verified: no code changes needed." "$GH_LOG" \
  && pass "artifact contents posted as a comment" \
  || fail "artifact contents not posted: $(cat "$GH_LOG")"
grep -qE "gh issue close $TASK .*--reason completed" "$GH_LOG" \
  && pass "sub-task #$TASK closed completed" \
  || fail "sub-task #$TASK not closed: $(cat "$GH_LOG")"
grep -qE '^=== gh workflow run autoducks-maestro\.yml .*feature_issue=99' "$GH_LOG" \
  && pass "Maestro explicitly re-dispatched on the parent feature" \
  || fail "no explicit Maestro re-dispatch: $(cat "$GH_LOG")"
if grep -qF "Agent run failed" "$GH_LOG"; then
  fail "notify_failure fired on the legitimate no-op"
else
  pass "notify_failure did not fire"
fi
if grep -q 'content=confused' "$GH_LOG"; then
  fail "confused reaction posted on the legitimate no-op"
else
  pass "no confused reaction posted"
fi
grep -qF "No code change" "$GH_LOG" \
  && pass "completion comment uses the no-code arm" \
  || fail "no-code completion arm text not found"

rm -f /tmp/no-code-result.md
echo ""

# =============================================================================
# 4. Empty diff + no artifact → genuine failure via assert_changes (scenario 3).
# =============================================================================
echo "── Empty diff + no artifact: fails via the existing assert_changes path ──"

TASK=103
fixture_issue "$TASK" "Nothing-produced task"
reset_state
new_task_branch "feature/99-issue-$TASK-a"
rm -f /tmp/no-code-result.md   # no diff, no artifact

RC=0
run_post "$TASK" "$FEATURE_BRANCH" || RC=$?
[[ "$RC" -eq 1 ]] && pass "exits 1" || fail "rc=$RC: $(tail -5 "$SCRATCH/stderr.log")"
if grep -q '^=== gh pr create ' "$GH_LOG"; then
  fail "a PR was created despite an empty diff and no artifact"
else
  pass "no PR created"
fi
if grep -qE "gh issue close $TASK " "$GH_LOG"; then
  fail "sub-task #$TASK was closed despite the failure"
else
  pass "sub-task #$TASK was not closed"
fi
grep -qF "Agent run failed" "$GH_LOG" \
  && pass "notify_failure fired" \
  || fail "notify_failure did not fire: $(cat "$GH_LOG")"
grep -q 'content=confused' "$GH_LOG" \
  && pass "confused reaction posted" \
  || fail "no confused reaction: $(cat "$GH_LOG")"

echo ""

# =============================================================================
# 5. Non-empty diff always creates a PR, even with a no-code artifact present
#    (diff wins — scenario 4).
# =============================================================================
echo "── Diff + artifact present: diff wins, PR still created, no-op skipped ──"

TASK=104
fixture_issue "$TASK" "Task with both a diff and a stray artifact"
reset_state
new_task_branch "feature/99-issue-$TASK-a"
make_diff
echo "Should be ignored: diff wins." > /tmp/no-code-result.md

RC=0
run_post "$TASK" "$FEATURE_BRANCH" || RC=$?
[[ "$RC" -eq 0 ]] && pass "exits 0" || fail "rc=$RC: $(tail -5 "$SCRATCH/stderr.log")"
grep -q '^=== gh pr create ' "$GH_LOG" && pass "PR created (diff wins)" || fail "no gh pr create: $(cat "$GH_LOG")"
if grep -qF "Should be ignored: diff wins." "$GH_LOG"; then
  fail "the no-code artifact was posted as a comment despite a non-empty diff"
else
  pass "the no-code artifact was not posted (no-op branch correctly skipped)"
fi
if grep -q '^=== gh workflow run autoducks-maestro.yml' "$GH_LOG"; then
  fail "Maestro was explicitly re-dispatched despite the diff path being taken"
else
  pass "no explicit Maestro re-dispatch on the diff path"
fi
grep -qE "gh issue close $TASK .*--reason completed" "$GH_LOG" \
  && pass "sub-task #$TASK closed via the normal (not no-op) close message" \
  || fail "sub-task #$TASK not closed: $(cat "$GH_LOG")"

rm -f /tmp/no-code-result.md

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "═══ developer post decision branch: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
