#!/usr/bin/env bash
# post.sh-level test for the architect's `error_max_turns` guard
# (.autoducks/agents/architect/post.sh), run end-to-end against a mocked `gh`
# CLI — the same shim convention used by test/unit-architect-guard.sh.
#
# Confirms a turn-limit cutoff is reported as `max_turns` (never
# `scope-missing`, even though /tmp/design-spec.md is also missing on that
# path) and that the LLM_SKIPPED path is untouched by the new branch.
# Run: bash test/unit-architect-post-max-turns.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

# ── gh shim: canned answers + call log ───────────────────────────────
mkdir -p "$SCRATCH/bin"
cat > "$SCRATCH/bin/gh" <<'SHIM'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"
case "$1" in
  issue)
    case "$2" in
      view)    cat "$MOCK_ISSUE_FILE" ;;
      comment) echo "https://github.com/x/y/issues/10#issuecomment-777" ;;
      *) : ;;
    esac
    ;;
  api)
    case "$2" in
      */comments|*/comments\?*) echo "[]" ;;
      *) : ;;
    esac
    ;;
  *) : ;;
esac
exit 0
SHIM
chmod +x "$SCRATCH/bin/gh"

MOCK_ISSUE_FILE="$SCRATCH/issue.json"
cat > "$MOCK_ISSUE_FILE" <<'JSON'
{"title": "Add search", "body": "designed body", "labels": ["Design:draft"], "author": "alice"}
JSON

clean_tmp() {
  rm -f /tmp/autoducks-pre-failed /tmp/autoducks-status-comment-id.10 \
        /tmp/architect-strip-tactical.flag /tmp/architect-dropped-tasks.txt \
        /tmp/design-spec.md
}

run_post() { # $1 = LLM_ERROR_SUBTYPE, $2 = LLM_SKIPPED
  export GH_LOG="$SCRATCH/gh.log"
  : > "$GH_LOG"
  export MOCK_ISSUE_FILE
  RC=0
  (
    PATH="$SCRATCH/bin:$PATH" \
    GITHUB_ACTIONS=true \
    ISSUE_NUM=10 REPO=x/y RUN_ID=999 COMMENT_ID=555 COMMENTER=alice \
    LLM_ERROR_SUBTYPE="${1:-}" LLM_SKIPPED="${2:-}" \
    GH_TOKEN=t \
    bash "$REPO_ROOT/.autoducks/agents/architect/post.sh"
  ) >/dev/null 2>&1 || RC=$?
}

# ---------------------------------------------------------------------------
echo "── Architect post: error_max_turns reported as max_turns, not scope-missing ──"
clean_tmp
run_post "error_max_turns" ""
[[ "$RC" -eq 1 ]] && pass "post exits 1" || fail "rc=$RC"
grep -qF '`max_turns`' "$GH_LOG" \
  && pass "failure comment carries the max_turns category" \
  || fail "max_turns category missing: $(cat "$GH_LOG")"
if grep -qF '`scope-missing`' "$GH_LOG"; then
  fail "failure comment mislabeled as scope-missing: $(cat "$GH_LOG")"
else
  pass "failure comment never mentions scope-missing"
fi
grep -q 'reactions.*content=confused' "$GH_LOG" \
  && pass "reacted confused" || fail "no confused reaction: $(cat "$GH_LOG")"
if grep -q 'workflow run autoducks-engineer' "$GH_LOG"; then
  fail "chain dispatch fired on a max_turns cutoff (should exit before it)"
else
  pass "chain::dispatch_next did not fire"
fi
clean_tmp

# ---------------------------------------------------------------------------
echo "── Architect post: no /tmp/design-spec.md AND error_max_turns ⇒ still max_turns ──"
clean_tmp
[[ ! -f /tmp/design-spec.md ]] || fail "test setup: design-spec.md unexpectedly present"
run_post "error_max_turns" ""
[[ "$RC" -eq 1 ]] && pass "post exits 1 with no design-spec.md present" || fail "rc=$RC"
grep -qF '`max_turns`' "$GH_LOG" \
  && pass "max_turns wins over the missing-output check" \
  || fail "max_turns category missing: $(cat "$GH_LOG")"
clean_tmp

# ---------------------------------------------------------------------------
echo "── Architect post: LLM_SKIPPED=true short-circuits before the max_turns branch ──"
clean_tmp
run_post "error_max_turns" "true"
[[ "$RC" -eq 0 ]] && pass "post exits 0 on the skip path" || fail "rc=$RC"
if grep -qF '`max_turns`' "$GH_LOG"; then
  fail "max_turns branch fired despite LLM_SKIPPED=true: $(cat "$GH_LOG")"
else
  pass "max_turns branch did not fire on the skip path"
fi
if grep -q 'content=confused' "$GH_LOG"; then
  fail "confused reaction posted on the skip path (should not react)"
else
  pass "no confused reaction on the skip path"
fi
clean_tmp

echo ""
echo "═══ architect-post-max-turns: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
