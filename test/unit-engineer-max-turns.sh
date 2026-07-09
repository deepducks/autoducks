#!/usr/bin/env bash
# Unit test for the Engineer's turn-limit handling
# (.autoducks/agents/engineer/post.sh with a mocked gh CLI).
#
# Asserts that a run that errored with error_max_turns before producing a
# tactical plan is categorized as max_turns (never mislabeled as the
# tactical-body-missing scope-missing case) and exits 1.
#
# Run: bash test/unit-engineer-max-turns.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

MARKER_RUN_ID="engineer-max-turns"

# ── gh shim: canned answers + call log ───────────────────────────────
mkdir -p "$SCRATCH/bin"
GH_LOG="$SCRATCH/gh.log"
: > "$GH_LOG"
cat > "$SCRATCH/bin/gh" <<'SHIM'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"
case "$1 $2" in
  "issue view")
    echo '{"title": "Add search", "body": "designed body", "labels": ["Design:done"], "author": "alice"}' ;;
  "issue comment")
    echo "https://github.com/x/y/issues/10#issuecomment-777" ;;
  *)
    : ;;
esac
exit 0
SHIM
chmod +x "$SCRATCH/bin/gh"

run_post() {
  # run_post: env passthrough via TEST_LLM_ERROR_SUBTYPE
  rm -rf "$SCRATCH/autoducks-$MARKER_RUN_ID"
  rm -f /tmp/tactical-body.md /tmp/questions.md /tmp/autoducks-status-comment-id.10
  : > "$GH_LOG"
  RC=0
  (
    PATH="$SCRATCH/bin:$PATH" \
    RUNNER_TEMP="$SCRATCH" \
    GITHUB_RUN_ID="$MARKER_RUN_ID" \
    GH_LOG="$GH_LOG" \
    GITHUB_ACTIONS=true \
    ISSUE_NUM=10 REPO=x/y RUN_ID=999 COMMENT_ID=555 COMMENTER=alice \
    COMMAND=engineer \
    LLM_ERROR_SUBTYPE="${TEST_LLM_ERROR_SUBTYPE:-}" \
    GH_TOKEN=t \
    bash "$REPO_ROOT/.autoducks/agents/engineer/post.sh"
  ) > "$SCRATCH/stdout.log" 2> "$SCRATCH/stderr.log" || RC=$?
}

echo "── turn-limit cutoff (no tactical-body.md) maps to max_turns, never scope-missing ──"
TEST_LLM_ERROR_SUBTYPE="error_max_turns" run_post
[[ "$RC" -eq 1 ]] && pass "post.sh exits 1 on error_max_turns" || fail "expected exit 1, got rc=$RC: $(tail -5 "$SCRATCH/stderr.log")"
grep -q 'AUTODUCKS_FAIL_CATEGORY=max_turns\|category.*max_turns\|max_turns' "$GH_LOG" \
  && pass "max_turns category surfaced via gh (comment/notification)" \
  || fail "no evidence of max_turns category in gh log: $(cat "$GH_LOG")"
if grep -qi 'scope-missing\|scope.missing' "$GH_LOG"; then
  fail "turn-limit cutoff was mislabeled as scope-missing"
else
  pass "turn-limit cutoff never labeled scope-missing"
fi

echo ""
echo "── sanity: absent LLM_ERROR_SUBTYPE still falls through to scope-missing (no tactical-body.md) ──"
TEST_LLM_ERROR_SUBTYPE="" run_post
[[ "$RC" -eq 1 ]] && pass "post.sh still exits 1 without a tactical plan" || fail "expected exit 1, got rc=$RC"
grep -q 'scope-missing' "$GH_LOG" \
  && pass "no-plan-without-max-turns path is unaffected (still scope-missing)" \
  || fail "expected the scope-missing path to still fire without LLM_ERROR_SUBTYPE: $(cat "$GH_LOG")"

echo ""
echo "═══ engineer-max-turns: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
