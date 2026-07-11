#!/usr/bin/env bash
# post.sh-level test for the capped verification loop
# (.autoducks/agents/developer/post.sh + core/robustness/verify-loop.sh).
#
# Runs the real developer/post.sh as a subprocess against a throwaway git
# repo (with a local bare "origin" so git::push_branch has somewhere real to
# push) and a shimmed `gh` CLI (same technique as
# test/unit-developer-idempotency.sh). AUTODUCKS_ROOT is redirected to a
# scratch copy of .autoducks so the checks config (`checks.enabled`,
# `checks.max_iterations`) can be set per-scenario without touching the
# real repo config, and core/robustness/verify-loop.sh is swapped for a
# tiny fake whose `run_checks` return code is controlled by an env var —
# this test is about the retry/give-up/infra wiring in post.sh, not the
# check-runner itself (already covered by test/unit-verify-loop.sh).
#
# Asserts:
#   1. rc=0 (pass)                 → PR path, feedback comment deleted
#   2. rc=1, iteration < max       → WIP push + re-dispatch(iteration+1),
#                                     no PR, exit 0
#   3. rc=1, iteration == max      → check_failed, branch preserved,
#                                     Work:coding aborted, exit 1, no PR
#   4. rc=2 (setup/infra)          → infra category, no iteration consumed,
#                                     no feedback comment, exit 1
#
# Run: bash test/unit-developer-verify-loop.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

REPO_NAME="acme/widgets"
ISSUE_NUM=42
GH_LOG="$SCRATCH/gh.log"
: > "$GH_LOG"

# ── Scratch AUTODUCKS_ROOT: a copy of the real .autoducks tree, so every
# core module post.sh sources is the real implementation, except the checks
# config (which we control per-scenario) and verify-loop.sh (faked below so
# run_checks' exit code is directly controllable). ──────────────────────
AUTODUCKS_SCRATCH_ROOT="$SCRATCH/dotautoducks"
cp -r "$REPO_ROOT/.autoducks" "$AUTODUCKS_SCRATCH_ROOT"

MAX_ITERATIONS=2
jq --argjson max "$MAX_ITERATIONS" '.checks = {enabled: true, max_iterations: $max}' \
  "$REPO_ROOT/.autoducks/autoducks.json" > "$AUTODUCKS_SCRATCH_ROOT/autoducks.json"

cat > "$AUTODUCKS_SCRATCH_ROOT/core/robustness/verify-loop.sh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
export AUTODUCKS_CHECK_FEEDBACK_MARKER="<!-- autoducks:check-feedback -->"
verify_loop::enabled() { [[ "${MOCK_CHECKS_ENABLED:-true}" == "true" ]]; }
verify_loop::run_checks() {
  [[ -n "${MOCK_RUN_CHECKS_LOG:-}" ]] && echo "called" >> "$MOCK_RUN_CHECKS_LOG"
  return "${MOCK_CHECKS_RC:-0}"
}
verify_loop::feedback_body() {
  printf '%s\n**Automated checks failed** (attempt %s/%s)\n' "$AUTODUCKS_CHECK_FEEDBACK_MARKER" "$1" "$2"
}
FAKE

# ── Throwaway git repo with a real local "origin" (bare repo), so
# git::push_branch has somewhere to push without touching GitHub. ────────
BARE="$SCRATCH/origin.git"
git init -q --bare "$BARE"
GIT_SCRATCH="$SCRATCH/work"
git init -q -b main "$GIT_SCRATCH"
git -C "$GIT_SCRATCH" config user.email "test@example.com"
git -C "$GIT_SCRATCH" config user.name "Test"
git -C "$GIT_SCRATCH" remote add origin "$BARE"
echo "seed" > "$GIT_SCRATCH/README.md"
git -C "$GIT_SCRATCH" add README.md
git -C "$GIT_SCRATCH" commit -q -m "seed"
git -C "$GIT_SCRATCH" push -q origin main

# ── gh shim: canned answers + call log (extends the idempotency shim's
# generic `api` path/method parser to also cover issue/pr/workflow verbs). ──
mkdir -p "$SCRATCH/bin"
cat > "$SCRATCH/bin/gh" <<'SHIM'
#!/usr/bin/env bash
{
  echo "=== gh $* ==="
} >> "$GH_LOG"

_next_comment_id() {
  local f="$SCRATCH/comment_counter"
  local n=1
  [[ -f "$f" ]] && n=$(($(cat "$f") + 1))
  echo "$n" > "$f"
  echo "$((9000 + n))"
}

case "$1" in
  issue)
    case "$2" in
      view)
        cat "${MOCK_ISSUE_FILE:-/dev/null}" 2>/dev/null || echo '{"title":"t","body":"b","labels":[],"author":"bob"}'
        ;;
      comment)
        echo "https://github.com/$REPO_NAME/issues/$3#issuecomment-$(_next_comment_id)"
        ;;
      edit) : ;;
      *) : ;;
    esac
    ;;
  pr)
    case "$2" in
      create) echo "https://github.com/$REPO_NAME/pull/777" ;;
      *) : ;;
    esac
    ;;
  workflow)
    : # dispatch — logged above, nothing else to do
    ;;
  label)
    : ;;
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
        -f)       prevflag="-f"; continue ;;
        *)
          if [[ "$prevflag" == "-f" ]]; then prevflag=""; continue; fi
          [[ -z "$path" ]] && path="$arg"
          ;;
      esac
    done
    if [[ "$path" == */issues/comments/*/reactions ]]; then
      : # reaction POST
    elif [[ "$path" == */issues/comments/* ]]; then
      : # its::update_comment (PATCH) / its::delete_comment (DELETE) — logged above
    elif [[ "$path" == */issues/*/comments* ]]; then
      cat "${MOCK_COMMENTS_FILE:-/dev/null}" 2>/dev/null || echo "[]"
    elif [[ "$path" == */issues/* ]]; then
      echo '""'   # its::get_issue's .type.name probe
    else
      :
    fi
    ;;
  *) : ;;
esac
exit 0
SHIM
chmod +x "$SCRATCH/bin/gh"

reset_run() {
  rm -f /tmp/autoducks-pre-failed /tmp/autoducks-dor-delegated \
        /tmp/autoducks-status-comment-id."$ISSUE_NUM" \
        /tmp/autoducks-check-feedback-comment-id."$ISSUE_NUM" \
        /tmp/task-spec.md /tmp/work-summary.md
  : > "$GH_LOG"
  rm -f "$SCRATCH/run_checks.log"
}

# run_post TASK_BRANCH [KEY=VAL ...]
# Checks out a fresh branch off main with an uncommitted change (so
# assert_changes passes), then runs the real post.sh against it.
run_post() {
  local branch="$1"; shift
  git -C "$GIT_SCRATCH" checkout -q main
  git -C "$GIT_SCRATCH" checkout -q -b "$branch"
  echo "llm edit for $branch" >> "$GIT_SCRATCH/README.md"
  local rc=0
  ( cd "$GIT_SCRATCH" && env -u GH_TOKEN -u GITHUB_TOKEN "$@" \
      PATH="$SCRATCH/bin:$PATH" \
      GH_LOG="$GH_LOG" \
      SCRATCH="$SCRATCH" \
      REPO_NAME="$REPO_NAME" \
      MOCK_ISSUE_FILE="${MOCK_ISSUE_FILE:-}" \
      MOCK_COMMENTS_FILE="${MOCK_COMMENTS_FILE:-}" \
      MOCK_CHECKS_ENABLED="${MOCK_CHECKS_ENABLED:-true}" \
      MOCK_CHECKS_RC="${MOCK_CHECKS_RC:-0}" \
      MOCK_RUN_CHECKS_LOG="$SCRATCH/run_checks.log" \
      AUTODUCKS_ROOT="$AUTODUCKS_SCRATCH_ROOT" \
      GITHUB_ACTIONS=true \
      REPO="$REPO_NAME" \
      ISSUE_NUM="$ISSUE_NUM" RUN_ID=999 COMMENT_ID=555 COMMENTER=bob \
      bash "$REPO_ROOT/.autoducks/agents/developer/post.sh" \
      > "$SCRATCH/stdout.log" 2> "$SCRATCH/stderr.log" ) || rc=$?
  return $rc
}

fixture_issue() {
  jq -n --arg t "$ISSUE_NUM" '{title: ("Task #" + $t), body: "Implement the thing.", labels: [], author: "bob"}' \
    > "$SCRATCH/issue.json"
  MOCK_ISSUE_FILE="$SCRATCH/issue.json"
}
fixture_issue

no_feedback_comments() { echo "[]" > "$SCRATCH/comments_empty.json"; MOCK_COMMENTS_FILE="$SCRATCH/comments_empty.json"; }
stale_feedback_comment() {
  jq -n '[{id: 501, author: "github-actions[bot]", body: "<!-- autoducks:check-feedback -->\n**Automated checks failed** (attempt 1/2)", updated_at: "2020-01-01T00:00:00Z", created_at: "2020-01-01T00:00:00Z"}]' \
    > "$SCRATCH/comments_stale.json"
  MOCK_COMMENTS_FILE="$SCRATCH/comments_stale.json"
}

# =============================================================================
# 1. Checks pass → push + PR path, stale feedback comment deleted
# =============================================================================
echo "── Developer post: checks pass → PR opened, feedback comment cleared ──"
stale_feedback_comment
reset_run
MOCK_CHECKS_ENABLED=true MOCK_CHECKS_RC=0
RC=0
run_post "feature/1-issue-$ISSUE_NUM-pass" ITERATION=1 MODEL=sonnet EFFORT=high MAX_TURNS=80 || RC=$?
[[ "$RC" -eq 0 ]] \
  && pass "pass: post.sh exits 0" \
  || fail "pass: rc=$RC: $(tail -20 "$SCRATCH/stderr.log")"
grep -q '=== gh pr create' "$GH_LOG" \
  && pass "pass: PR was created" \
  || fail "pass: no 'gh pr create' call found"
grep -q '=== gh api .*issues/comments/501 --method DELETE' "$GH_LOG" \
  && pass "pass: stale feedback comment (id 501) was deleted" \
  || fail "pass: feedback comment was not deleted: $(cat "$GH_LOG")"
if grep -q 'workflow run autoducks-developer.yml' "$GH_LOG"; then
  fail "pass: unexpectedly re-dispatched autoducks-developer.yml"
else
  pass "pass: no re-dispatch"
fi

echo ""

# =============================================================================
# 2. Checks fail, iteration (1) < max (2) → WIP push + re-dispatch, no PR
# =============================================================================
echo "── Developer post: check fails, iteration < max → re-dispatch, no PR ──"
no_feedback_comments
reset_run
MOCK_CHECKS_ENABLED=true MOCK_CHECKS_RC=1
RC=0
run_post "feature/1-issue-$ISSUE_NUM-retry" ITERATION=1 MODEL=sonnet EFFORT=high MAX_TURNS=80 || RC=$?
[[ "$RC" -eq 0 ]] \
  && pass "retry: post.sh exits 0 (this iteration ends cleanly)" \
  || fail "retry: rc=$RC: $(tail -20 "$SCRATCH/stderr.log")"
if grep -q '=== gh pr create' "$GH_LOG"; then
  fail "retry: a PR was opened despite the failing check"
else
  pass "retry: no PR opened"
fi
grep -q 'workflow run autoducks-developer.yml' "$GH_LOG" \
  && pass "retry: re-dispatched autoducks-developer.yml" \
  || fail "retry: no re-dispatch found: $(cat "$GH_LOG")"
grep -qE -- '-f iteration=2\b' "$GH_LOG" \
  && pass "retry: re-dispatch carries iteration=2" \
  || fail "retry: iteration=2 not found in dispatch args: $(grep 'workflow run' "$GH_LOG")"
grep -qE -- '-f actor=bob' "$GH_LOG" \
  && pass "retry: re-dispatch propagates actor" \
  || fail "retry: actor not propagated: $(grep 'workflow run' "$GH_LOG")"
grep -qE -- '-f model=sonnet' "$GH_LOG" \
  && pass "retry: re-dispatch propagates model" \
  || fail "retry: model not propagated: $(grep 'workflow run' "$GH_LOG")"
grep -qE -- '-f effort=high' "$GH_LOG" \
  && pass "retry: re-dispatch propagates effort" \
  || fail "retry: effort not propagated: $(grep 'workflow run' "$GH_LOG")"
grep -qE -- '-f max_turns=80' "$GH_LOG" \
  && pass "retry: re-dispatch propagates max_turns" \
  || fail "retry: max_turns not propagated: $(grep 'workflow run' "$GH_LOG")"
grep -q 'attempt 1/2' "$GH_LOG" \
  && pass "retry: feedback comment upserted with the check output (marker-anchored)" \
  || fail "retry: feedback comment body missing: $(cat "$GH_LOG")"
grep -q 'retrying (2/2)' "$GH_LOG" \
  && pass "retry: status comment carries the retry breadcrumb" \
  || fail "retry: retry breadcrumb missing: $(cat "$GH_LOG")"
git -C "$BARE" show-ref --verify --quiet "refs/heads/feature/1-issue-$ISSUE_NUM-retry" \
  && pass "retry: WIP branch was pushed to origin (resumable)" \
  || fail "retry: branch was not pushed to origin"

echo ""

# =============================================================================
# 3. Checks fail, iteration (2) == max (2) → check_failed give-up, no PR
# =============================================================================
echo "── Developer post: check fails, iteration == max → check_failed give-up ──"
no_feedback_comments
reset_run
MOCK_CHECKS_ENABLED=true MOCK_CHECKS_RC=1
RC=0
run_post "feature/1-issue-$ISSUE_NUM-giveup" ITERATION=2 || RC=$?
[[ "$RC" -eq 1 ]] \
  && pass "give-up: post.sh exits 1" \
  || fail "give-up: rc=$RC: $(tail -20 "$SCRATCH/stderr.log")"
if grep -q '=== gh pr create' "$GH_LOG"; then
  fail "give-up: a PR was opened despite giving up"
else
  pass "give-up: no PR opened"
fi
if grep -q 'workflow run autoducks-developer.yml' "$GH_LOG"; then
  fail "give-up: unexpectedly re-dispatched (should have given up)"
else
  pass "give-up: no re-dispatch"
fi
grep -q '`check_failed`' "$GH_LOG" \
  && pass "give-up: failure categorized as check_failed" \
  || fail "give-up: check_failed category missing: $(cat "$GH_LOG")"
git -C "$BARE" show-ref --verify --quiet "refs/heads/feature/1-issue-$ISSUE_NUM-giveup" \
  && pass "give-up: branch was preserved (pushed) for /fix" \
  || fail "give-up: branch was not preserved"
grep -q "issue edit $ISSUE_NUM --repo $REPO_NAME --remove-label Work:coding" "$GH_LOG" \
  && pass "give-up: Work:coding progress label aborted" \
  || fail "give-up: Work:coding was not aborted: $(cat "$GH_LOG")"

echo ""

# =============================================================================
# 4. Setup/infra error (rc=2) → infra category, no iteration consumed
# =============================================================================
echo "── Developer post: setup error → infra, no iteration consumed ──"
stale_feedback_comment
reset_run
MOCK_CHECKS_ENABLED=true MOCK_CHECKS_RC=2
RC=0
run_post "feature/1-issue-$ISSUE_NUM-infra" ITERATION=1 || RC=$?
[[ "$RC" -eq 1 ]] \
  && pass "infra: post.sh exits 1" \
  || fail "infra: rc=$RC: $(tail -20 "$SCRATCH/stderr.log")"
grep -q '`infra`' "$GH_LOG" \
  && pass "infra: failure categorized as infra" \
  || fail "infra: infra category missing: $(cat "$GH_LOG")"
if grep -q '`check_failed`' "$GH_LOG"; then
  fail "infra: mislabeled as check_failed"
else
  pass "infra: never mislabeled as check_failed"
fi
if grep -q 'workflow run autoducks-developer.yml' "$GH_LOG"; then
  fail "infra: unexpectedly re-dispatched (no iteration should be consumed)"
else
  pass "infra: no re-dispatch (iteration not consumed)"
fi
if grep -q '=== gh pr create' "$GH_LOG"; then
  fail "infra: a PR was opened despite the setup error"
else
  pass "infra: no PR opened"
fi
if grep -q 'attempt' "$GH_LOG"; then
  fail "infra: a check-feedback comment was upserted (should be skipped on infra)"
else
  pass "infra: no feedback comment upserted"
fi
grep -q '=== gh api .*issues/comments/501 --method DELETE' "$GH_LOG" \
  && pass "infra: stale feedback comment cleared (#989)" \
  || fail "infra: stale feedback comment was not cleared: $(cat "$GH_LOG")"

# =============================================================================
# 5. Give-up with an iters override reports the ENFORCED cap, not the config
#    default (#989 — the give-up message must sync $MAX).
# =============================================================================
echo "── Developer post: give-up reports the overridden cap, not the config default ──"
no_feedback_comments
reset_run
MOCK_CHECKS_ENABLED=true MOCK_CHECKS_RC=1
RC=0
run_post "feature/1-issue-$ISSUE_NUM-capoverride" ITERATION=5 MAX_ITERATIONS=5 || RC=$?
[[ "$RC" -eq 1 ]] \
  && pass "cap: post.sh exits 1 (give-up)" \
  || fail "cap: rc=$RC: $(tail -20 "$SCRATCH/stderr.log")"
grep -q 'after 5 iterations' "$GH_LOG" \
  && pass "cap: give-up reports the enforced cap (5), not the config default (2)" \
  || fail "cap: message did not report the enforced cap: $(cat "$GH_LOG")"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "═══ developer verify-loop: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
