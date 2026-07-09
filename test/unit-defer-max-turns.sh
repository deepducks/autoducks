#!/usr/bin/env bash
# Regression test: `.autoducks/agents/defer/post.sh` must classify a
# turn-limit cutoff (LLM_ERROR_SUBTYPE=error_max_turns) as `max_turns`, never
# mislabel it as `scope-missing` just because /tmp/defer-issue.md is absent —
# and the pre-existing defer-none.md green-skip / LLM_SKIPPED skip paths must
# stay unaffected by the new branch.
#
# Runs the real defer/post.sh as a subprocess with `gh` shimmed out (same
# technique as test/unit-idempotency.sh) — no network access.
#
# Run: bash test/unit-defer-max-turns.sh
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
# Every `gh issue comment` body this run posted (notify_failure's diagnostic
# comment AND status_comment::fail's status-comment fallback both post via
# `gh issue comment` when no status-comment id file exists), appended with a
# separator so the test can grep across all of them rather than just the last.
ALL_COMMENT_BODIES="$SCRATCH/all_comment_bodies.txt"

# ── gh shim ───────────────────────────────────────────────────────────────
# defer/post.sh reaches the outside world only through its::*, which bottoms
# out in `gh`. Putting a fake `gh` first on PATH lets the real post.sh run
# unmodified, and captures the body of every `gh issue comment` call so the
# test can assert on the failure category baked into it.
mkdir -p "$SCRATCH/bin"
cat > "$SCRATCH/bin/gh" <<'SHIM'
#!/usr/bin/env bash
{
  echo "=== gh $* ==="
} >> "$GH_LOG"

case "$1 $2" in
  "issue comment")
    prev=""
    for arg in "$@"; do
      if [[ "$prev" == "--body" ]]; then
        {
          printf '%s' "$arg"
          echo ""
          echo "--- END COMMENT ---"
        } >> "$ALL_COMMENT_BODIES"
      fi
      prev="$arg"
    done
    echo "https://github.com/x/y/issues/$3#issuecomment-777"
    ;;
  *) : ;;
esac
exit 0
SHIM
chmod +x "$SCRATCH/bin/gh"

DEFER_POST="$REPO_ROOT/.autoducks/agents/defer/post.sh"

# run_step [KEY=VAL ...]
# Runs the real defer/post.sh as a subprocess (its own `set -e`, its own ERR
# trap) with the shim first on PATH. Prints stderr and returns the script's
# exit code so callers can assert on it.
run_step() {
  local rc=0
  env "$@" \
    PATH="$SCRATCH/bin:$PATH" \
    RUNNER_TEMP="$SCRATCH" \
    GITHUB_RUN_ID="defer-max-turns" \
    GH_LOG="$GH_LOG" \
    ALL_COMMENT_BODIES="$ALL_COMMENT_BODIES" \
    GITHUB_ACTIONS=true \
    GH_TOKEN=t \
    REPO="$REPO_NAME" \
    bash "$DEFER_POST" > "$SCRATCH/stdout.log" 2> "$SCRATCH/stderr.log" || rc=$?
  return $rc
}

reset_run() {
  rm -f /tmp/defer-none.md /tmp/defer-issue.md /tmp/defer-issue-final.md /tmp/defer-context.md
  rm -f /tmp/autoducks-status-comment-id.*
  rm -rf "$SCRATCH/autoducks-defer-max-turns"
  : > "$GH_LOG"
  : > "$ALL_COMMENT_BODIES"
}

# =============================================================================
# 1. error_max_turns + no defer-issue.md ⇒ max_turns category, exit 1
# =============================================================================
echo "── error_max_turns with no defer-issue.md maps to max_turns, not scope-missing ──"

reset_run
RC=0
run_step ISSUE_NUM=500 RUN_ID=900 COMMENT_ID=1 LLM_ERROR_SUBTYPE=error_max_turns || RC=$?

[[ "$RC" -eq 1 ]] \
  && pass "exits 1" \
  || fail "expected exit 1, got rc=$RC: $(tail -5 "$SCRATCH/stderr.log")"

BODY="$(cat "$ALL_COMMENT_BODIES" 2>/dev/null || true)"
if echo "$BODY" | grep -qF '**Category:** `max_turns`'; then
  pass "failure comment reports Category: max_turns"
else
  fail "failure comment did not report Category: max_turns, got: $BODY"
fi
if echo "$BODY" | grep -qF 'scope-missing'; then
  fail "failure comment incorrectly mentions scope-missing"
else
  pass "failure comment never mentions scope-missing"
fi
if grep -q 'reactions.*content=confused' "$GH_LOG"; then
  pass "reacted confused"
else
  fail "did not react confused: $(cat "$GH_LOG")"
fi

echo ""

# =============================================================================
# 2. Baseline unaffected: no LLM_ERROR_SUBTYPE + no defer-issue.md ⇒ still
#    scope-missing, exit 1
# =============================================================================
echo "── Baseline: missing defer-issue.md with no turn-limit error still maps to scope-missing ──"

reset_run
RC=0
run_step ISSUE_NUM=501 RUN_ID=901 COMMENT_ID=1 || RC=$?

[[ "$RC" -eq 1 ]] \
  && pass "exits 1" \
  || fail "expected exit 1, got rc=$RC: $(tail -5 "$SCRATCH/stderr.log")"

BODY="$(cat "$ALL_COMMENT_BODIES" 2>/dev/null || true)"
if echo "$BODY" | grep -qF '**Category:** `scope-missing`'; then
  pass "failure comment reports Category: scope-missing (unchanged baseline)"
else
  fail "failure comment did not report Category: scope-missing, got: $BODY"
fi

echo ""

# =============================================================================
# 3. defer-none.md green-skip path is unaffected even when
#    LLM_ERROR_SUBTYPE=error_max_turns is also set
# =============================================================================
echo "── defer-none.md green-skip path is unaffected by LLM_ERROR_SUBTYPE ──"

reset_run
echo "No actionable feedback found." > /tmp/defer-none.md
RC=0
run_step ISSUE_NUM=502 RUN_ID=902 COMMENT_ID=1 LLM_ERROR_SUBTYPE=error_max_turns || RC=$?

[[ "$RC" -eq 0 ]] \
  && pass "green-skip: exits 0" \
  || fail "green-skip: expected exit 0, got rc=$RC: $(tail -5 "$SCRATCH/stderr.log")"
if grep -q 'reactions.*content=confused' "$GH_LOG"; then
  fail "green-skip: unexpectedly reacted confused"
else
  pass "green-skip: no confused reaction"
fi
rm -f /tmp/defer-none.md

echo ""

# =============================================================================
# 4. LLM_SKIPPED=true skip path is unaffected by LLM_ERROR_SUBTYPE
# =============================================================================
echo "── LLM_SKIPPED skip path is unaffected by LLM_ERROR_SUBTYPE ──"

reset_run
RC=0
run_step ISSUE_NUM=503 RUN_ID=903 COMMENT_ID=1 LLM_SKIPPED=true LLM_ERROR_SUBTYPE=error_max_turns || RC=$?

[[ "$RC" -eq 0 ]] \
  && pass "LLM_SKIPPED: exits 0" \
  || fail "LLM_SKIPPED: expected exit 0, got rc=$RC: $(tail -5 "$SCRATCH/stderr.log")"
if grep -q 'reactions.*content=confused' "$GH_LOG"; then
  fail "LLM_SKIPPED: unexpectedly reacted confused"
else
  pass "LLM_SKIPPED: no confused reaction"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "═══ defer max_turns wiring: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
