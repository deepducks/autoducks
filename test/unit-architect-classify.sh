#!/usr/bin/env bash
# post.sh-level test for the Architect's issue classification
# (.autoducks/agents/architect/post.sh), run end-to-end against a mocked `gh`
# CLI — the same shim convention used by test/unit-architect-guard.sh.
#
# Confirms /tmp/issue-type drives both the native type and the authoritative
# Feature/Bug label, that the opposite label is stripped, and that both
# provisional Intake:* labels are always stripped alongside it so a guess
# never lingers next to a confirmed classification.
# Run: bash test/unit-architect-classify.sh
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

clean_tmp() {
  rm -f /tmp/autoducks-pre-failed /tmp/autoducks-status-comment-id.10 \
        /tmp/architect-strip-tactical.flag /tmp/architect-dropped-tasks.txt \
        /tmp/issue-type
  echo "## Problem Statement

Design output." > /tmp/design-spec.md
}

run_post() { # $1 = issue-type value to write to /tmp/issue-type
  export GH_LOG="$SCRATCH/gh.log"
  : > "$GH_LOG"
  export MOCK_ISSUE_FILE
  if [[ -n "${1:-}" ]]; then
    printf '%s' "$1" > /tmp/issue-type
  fi
  RC=0
  (
    PATH="$SCRATCH/bin:$PATH" \
    GITHUB_ACTIONS=true \
    ISSUE_NUM=10 REPO=x/y RUN_ID=999 COMMENT_ID=555 COMMENTER=alice \
    GH_TOKEN=t \
    bash "$REPO_ROOT/.autoducks/agents/architect/post.sh"
  ) >/dev/null 2>&1 || RC=$?
}

# ---------------------------------------------------------------------------
echo "── Architect classify: Bug outcome sets native type + label, strips Feature and both Intake:* labels ──"
clean_tmp
cat > "$MOCK_ISSUE_FILE" <<'JSON'
{"title": "Crash on save", "body": "steps to repro", "labels": ["Design:draft", "Intake:Bug"], "author": "alice"}
JSON
run_post "Bug"
[[ "$RC" -eq 0 ]] && pass "post exits 0" || fail "rc=$RC"
grep -q 'api repos/x/y/issues/10 --method PATCH -f type=Bug' "$GH_LOG" \
  && pass "native type set to Bug" || fail "type not set: $(cat "$GH_LOG")"
grep -q 'issue edit 10 --repo x/y --add-label Bug' "$GH_LOG" \
  && pass "Bug label added" || fail "Bug label not added: $(cat "$GH_LOG")"
grep -q 'issue edit 10 --repo x/y --remove-label Feature' "$GH_LOG" \
  && pass "opposite Feature label stripped" || fail "Feature label not stripped: $(cat "$GH_LOG")"
grep -q 'issue edit 10 --repo x/y --remove-label Intake:Bug' "$GH_LOG" \
  && pass "Intake:Bug stripped" || fail "Intake:Bug not stripped: $(cat "$GH_LOG")"
grep -q 'issue edit 10 --repo x/y --remove-label Intake:Feature' "$GH_LOG" \
  && pass "Intake:Feature stripped" || fail "Intake:Feature not stripped: $(cat "$GH_LOG")"
clean_tmp

# ---------------------------------------------------------------------------
echo "── Architect classify: Feature outcome sets native type + label, strips Bug and both Intake:* labels ──"
clean_tmp
cat > "$MOCK_ISSUE_FILE" <<'JSON'
{"title": "Add search", "body": "feature request", "labels": ["Design:draft", "Intake:Feature"], "author": "alice"}
JSON
run_post "Feature"
[[ "$RC" -eq 0 ]] && pass "post exits 0" || fail "rc=$RC"
grep -q 'api repos/x/y/issues/10 --method PATCH -f type=Feature' "$GH_LOG" \
  && pass "native type set to Feature" || fail "type not set: $(cat "$GH_LOG")"
grep -q 'issue edit 10 --repo x/y --add-label Feature' "$GH_LOG" \
  && pass "Feature label added" || fail "Feature label not added: $(cat "$GH_LOG")"
grep -q 'issue edit 10 --repo x/y --remove-label Bug' "$GH_LOG" \
  && pass "opposite Bug label stripped" || fail "Bug label not stripped: $(cat "$GH_LOG")"
grep -q 'issue edit 10 --repo x/y --remove-label Intake:Bug' "$GH_LOG" \
  && pass "Intake:Bug stripped" || fail "Intake:Bug not stripped: $(cat "$GH_LOG")"
grep -q 'issue edit 10 --repo x/y --remove-label Intake:Feature' "$GH_LOG" \
  && pass "Intake:Feature stripped" || fail "Intake:Feature not stripped: $(cat "$GH_LOG")"
clean_tmp

echo ""
echo "═══ architect-classify: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
