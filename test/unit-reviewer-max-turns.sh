#!/usr/bin/env bash
# Unit test for the `error_max_turns` branch added to
# .autoducks/agents/reviewer/post.sh: a turn-limit cutoff (no /tmp/review.md
# ever produced) must map to AUTODUCKS_FAIL_CATEGORY=max_turns — never
# scope-missing — abort Review:reviewing on every REVIEW_TARGETS entry,
# conclude the Check-run `failure` when CHECK_RUN_ID is set, and exit 1.
# Also locks that the pre-existing LLM_SKIPPED (neutral Check-run) path,
# which sits immediately above the new branch, is unaffected.
#
# Runs the real reviewer/post.sh as a subprocess with `gh` shimmed out (same
# technique as test/unit-developer-idempotency.sh) so the real notify-failure/
# progress-labels/status-comment/check-run code paths execute for real
# without touching GitHub.
#
# Run: bash test/unit-reviewer-max-turns.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POST_SH="$REPO_ROOT/.autoducks/agents/reviewer/post.sh"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

REPO_NAME="acme/widgets"
GH_LOG="$SCRATCH/gh.log"
BODIES_LOG="$SCRATCH/bodies.log"

mkdir -p "$SCRATCH/bin"
cat > "$SCRATCH/bin/gh" <<'SHIM'
#!/usr/bin/env bash
echo "CALL: $*" >> "$GH_LOG"

if [[ "$1" == "issue" && "$2" == "comment" ]]; then
  echo "COMMENT_ISSUE:$3" >> "$GH_LOG"
  prev=""
  for a in "$@"; do
    [[ "$prev" == "--body" ]] && printf '%s\n---\n' "$a" >> "$BODIES_LOG"
    prev="$a"
  done
  echo "https://github.com/x/y/issues/$3#issuecomment-91"
  exit 0
fi

if [[ "$1" == "issue" && "$2" == "edit" ]]; then
  prev="" label=""
  for a in "$@"; do
    [[ "$prev" == "--remove-label" ]] && label="$a"
    prev="$a"
  done
  echo "REMOVE:$3:$label" >> "$GH_LOG"
  exit 0
fi

if [[ "$1" == "api" ]]; then
  is_checkrun=false
  is_reaction=false
  for a in "$@"; do
    case "$a" in
      */check-runs/*) is_checkrun=true ;;
      */reactions)     is_reaction=true ;;
    esac
  done
  if $is_checkrun; then
    body_json=$(cat)
    conclusion=$(printf '%s' "$body_json" | jq -r '.conclusion // empty' 2>/dev/null)
    echo "CHECKRUN_PATCH:conclusion=$conclusion" >> "$GH_LOG"
    echo '{"id":1}'
  elif $is_reaction; then
    echo "REACTION:posted" >> "$GH_LOG"
  fi
  exit 0
fi

exit 0
SHIM
chmod +x "$SCRATCH/bin/gh"

# run_post [KEY=VAL ...]
# Runs reviewer/post.sh as a real subprocess, its own set -e / ERR trap, with
# the gh shim first on PATH and a fresh RUNNER_TEMP (so the
# AUTODUCKS_PRE_FAILED_MARKER short-circuit never trips) and REPO fixed.
run_post() {
  local rc=0
  local runner_temp="$SCRATCH/runnertemp-$RANDOM"
  mkdir -p "$runner_temp"
  ( env "$@" \
      PATH="$SCRATCH/bin:$PATH" \
      GH_LOG="$GH_LOG" \
      BODIES_LOG="$BODIES_LOG" \
      RUNNER_TEMP="$runner_temp" \
      GITHUB_ACTIONS=true \
      GH_TOKEN=t \
      GITHUB_TOKEN=t \
      REPO="$REPO_NAME" \
      bash "$POST_SH" > "$SCRATCH/stdout.log" 2> "$SCRATCH/stderr.log" ) || rc=$?
  return $rc
}

reset_run() {
  : > "$GH_LOG"
  : > "$BODIES_LOG"
  rm -f /tmp/review.md /tmp/review-verdict /tmp/work-summary.md
  rm -f /tmp/autoducks-status-comment-id.500 /tmp/autoducks-status-comment-id.77
}

# =============================================================================
# 1. error_max_turns, no CHECK_RUN_ID → max_turns category, both targets
#    aborted, exit 1, never scope-missing
# =============================================================================
echo "── error_max_turns (no CHECK_RUN_ID): max_turns category, exit 1 ──"
reset_run
RC=0
run_post ISSUE_NUM=500 RUN_ID=999 COMMENT_ID=42 COMMENTER=bob \
  REVIEW_TARGETS_CSV="500,77" LLM_ERROR_SUBTYPE=error_max_turns MAX_TURNS=100 \
  JOB_STATUS=success || RC=$?

[[ "$RC" -eq 1 ]] \
  && pass "exits 1" \
  || fail "expected exit 1, got rc=$RC: $(tail -5 "$SCRATCH/stderr.log")"

if grep -qF '`max_turns`' "$BODIES_LOG"; then
  pass "failure comment carries the max_turns category"
else
  fail "max_turns category missing from comment body(s): $(cat "$BODIES_LOG")"
fi

if grep -qF '`scope-missing`' "$BODIES_LOG"; then
  fail "failure comment incorrectly carries scope-missing"
else
  pass "failure comment never mislabels the cutoff as scope-missing"
fi

if grep -qF 'turn limit' "$BODIES_LOG"; then
  pass "diagnosis mentions the turn limit"
else
  fail "diagnosis missing turn-limit wording: $(cat "$BODIES_LOG")"
fi

if grep -q '^REACTION:posted$' "$GH_LOG"; then
  pass "reacts confused"
else
  fail "confused reaction missing: $(cat "$GH_LOG")"
fi

if grep -q '^REMOVE:500:Review:reviewing$' "$GH_LOG" && grep -q '^REMOVE:77:Review:reviewing$' "$GH_LOG"; then
  pass "Review:reviewing aborted on every REVIEW_TARGETS entry (500 and 77)"
else
  fail "Review:reviewing not aborted on both targets: $(cat "$GH_LOG")"
fi

if grep -q '^CHECKRUN_PATCH:' "$GH_LOG"; then
  fail "check-run conclude called despite CHECK_RUN_ID being unset: $(cat "$GH_LOG")"
else
  pass "no check-run conclude call when CHECK_RUN_ID is unset"
fi

echo ""

# =============================================================================
# 2. error_max_turns, CHECK_RUN_ID set → concludes the Check-run `failure`
# =============================================================================
echo "── error_max_turns (CHECK_RUN_ID set): concludes Check-run failure ──"
reset_run
RC=0
run_post ISSUE_NUM=500 RUN_ID=999 COMMENT_ID=42 COMMENTER=bob \
  REVIEW_TARGETS_CSV="500,77" LLM_ERROR_SUBTYPE=error_max_turns MAX_TURNS=100 \
  JOB_STATUS=success CHECK_RUN_ID=778899 || RC=$?

[[ "$RC" -eq 1 ]] \
  && pass "exits 1" \
  || fail "expected exit 1, got rc=$RC: $(tail -5 "$SCRATCH/stderr.log")"

if grep -q '^CHECKRUN_PATCH:conclusion=failure$' "$GH_LOG"; then
  pass "Check-run concluded failure"
else
  fail "Check-run not concluded failure: $(cat "$GH_LOG")"
fi

echo ""

# =============================================================================
# 3. Regression: LLM_SKIPPED path is unchanged (neutral Check-run, no
#    confused reaction, exit 0) — sits immediately above the new branch
# =============================================================================
echo "── LLM_SKIPPED unchanged: neutral Check-run, exit 0, no confused reaction ──"
reset_run
RC=0
run_post ISSUE_NUM=500 RUN_ID=999 COMMENT_ID=42 COMMENTER=bob \
  REVIEW_TARGETS_CSV="500,77" LLM_SKIPPED=true JOB_STATUS=success \
  CHECK_RUN_ID=778899 || RC=$?

[[ "$RC" -eq 0 ]] \
  && pass "exits 0" \
  || fail "expected exit 0, got rc=$RC: $(tail -5 "$SCRATCH/stderr.log")"

if grep -q '^CHECKRUN_PATCH:conclusion=neutral$' "$GH_LOG"; then
  pass "Check-run concluded neutral"
else
  fail "Check-run not concluded neutral: $(cat "$GH_LOG")"
fi

if grep -q '^REACTION:posted$' "$GH_LOG"; then
  fail "LLM_SKIPPED incorrectly reacted confused"
else
  pass "LLM_SKIPPED does not react confused"
fi

if grep -qF '`max_turns`' "$BODIES_LOG"; then
  fail "LLM_SKIPPED path incorrectly carries the max_turns category"
else
  pass "LLM_SKIPPED path untouched by the new max_turns branch"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "═══ reviewer max_turns: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
