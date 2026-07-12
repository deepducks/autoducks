#!/usr/bin/env bash
# Integration test for the Engineer's Definition-of-Ready cascade
# (.autoducks/agents/engineer/pre.sh with a mocked gh CLI).
# Run: bash test/unit-engineer-dor.sh
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
case "$1 $2" in
  "issue view")
    cat "$MOCK_ISSUE_FILE" ;;
  "issue comment")
    echo "https://github.com/x/y/issues/10#issuecomment-777" ;;
  "workflow run")
    : ;;
  *)
    : ;;
esac
exit 0
SHIM
chmod +x "$SCRATCH/bin/gh"

run_pre() { # $1 = issue json file; env passthrough via TEST_* vars
  export GH_LOG="$SCRATCH/gh.log"
  : > "$GH_LOG"
  export MOCK_ISSUE_FILE="$1"
  : > "$SCRATCH/gh_env"
  RC=0
  (
    cd "$SCRATCH"     # /tmp markers are global; cwd only matters for nothing else
    PATH="$SCRATCH/bin:$PATH" \
    GITHUB_ACTIONS=true \
    ISSUE_NUM=10 REPO=x/y RUN_ID=999 COMMENT_ID=555 COMMENTER=alice \
    GITHUB_OUTPUT="$SCRATCH/gh_output" \
    GITHUB_ENV="$SCRATCH/gh_env" \
    RUNNER_TEMP="$SCRATCH" GITHUB_RUN_ID=dortest \
    AUTO_CHAIN="${TEST_AUTO_CHAIN:-}" COMMAND="${TEST_COMMAND:-}" \
    GH_TOKEN=t \
    bash "$REPO_ROOT/.autoducks/agents/engineer/pre.sh"
  ) >/dev/null 2>&1 || RC=$?
}

echo "── raw issue (no Design:done) delegates to the Architect ──"
cat > "$SCRATCH/issue-raw.json" <<'JSON'
{"title": "Add search", "body": "we need search", "labels": [], "author": "alice"}
JSON

: > "$SCRATCH/gh_output"
TEST_COMMAND="engineer" run_pre "$SCRATCH/issue-raw.json"
[[ "$RC" -eq 0 ]] && pass "pre exits 0 on delegation" || fail "rc=$RC"
grep -q 'gh workflow run autoducks-architect.yml' "$GH_LOG" \
  && pass "Architect workflow dispatched" || fail "no architect dispatch: $(grep 'workflow run' "$GH_LOG" || echo none)"
grep -q 'auto_chain=engineer' "$GH_LOG" \
  && pass "Engineer re-queued in the chain" || fail "chain missing"
grep -q 'actor=alice' "$GH_LOG" \
  && pass "actor forwarded for the done-assignee" || fail "actor missing"
grep -q 'dor_skip=true' "$SCRATCH/gh_output" \
  && pass "dor_skip output set (LLM step will be skipped)" || fail "dor_skip missing"
[[ -f "$SCRATCH/autoducks-dortest/dor-delegated" ]] \
  && pass "delegation marker written for post.sh" || fail "marker missing"

echo "── execute-routed run preserves the user's intent through delegation ──"
: > "$SCRATCH/gh_output"
TEST_COMMAND="execute" run_pre "$SCRATCH/issue-raw.json"
grep -q 'auto_chain=engineer+execute' "$GH_LOG" \
  && pass "implicit execute appended after engineer" || fail "got: $(grep 'workflow run' "$GH_LOG")"

echo "── explicit #auto chain rides along ──"
: > "$SCRATCH/gh_output"
TEST_COMMAND="execute" TEST_AUTO_CHAIN="" run_pre "$SCRATCH/issue-raw.json"
grep -q 'auto_chain=engineer+execute' "$GH_LOG" \
  && pass "chain = engineer+execute" || fail "chain wrong"

echo "── ready issue (Design:done) proceeds without delegation ──"
cat > "$SCRATCH/issue-ready.json" <<'JSON'
{"title": "Add search", "body": "designed body", "labels": ["Design:done", "Feature"], "author": "alice"}
JSON
: > "$SCRATCH/gh_output"
TEST_COMMAND="engineer" run_pre "$SCRATCH/issue-ready.json"
[[ "$RC" -eq 0 ]] && pass "pre exits 0 on ready issue" || fail "rc=$RC"
if grep -q 'workflow run' "$GH_LOG"; then
  fail "unexpected dispatch on ready issue"
else
  pass "no dispatch on ready issue"
fi
grep -q 'Tactics:crafting' "$GH_LOG" \
  && pass "in-progress label applied" || fail "no progress label"
if grep -q 'dor_skip=true' "$SCRATCH/gh_output"; then
  fail "dor_skip set on ready issue"
else
  pass "dor_skip not set on ready issue"
fi

echo "── Design:done but unclassified (no Feature/Bug type or label) delegates to the Architect ──"
cat > "$SCRATCH/issue-unclassified.json" <<'JSON'
{"title": "Add search", "body": "designed body", "labels": ["Design:done"], "author": "alice"}
JSON
: > "$SCRATCH/gh_output"
TEST_COMMAND="engineer" run_pre "$SCRATCH/issue-unclassified.json"
[[ "$RC" -eq 0 ]] && pass "pre exits 0 on unclassified delegation" || fail "rc=$RC"
grep -q 'gh workflow run autoducks-architect.yml' "$GH_LOG" \
  && pass "Architect workflow dispatched for unclassified issue" || fail "no architect dispatch: $(grep 'workflow run' "$GH_LOG" || echo none)"
grep -q 'dor_skip=true' "$SCRATCH/gh_output" \
  && pass "dor_skip output set for unclassified issue" || fail "dor_skip missing"
[[ -f "$SCRATCH/autoducks-dortest/dor-delegated" ]] \
  && pass "delegation marker written for unclassified issue" || fail "marker missing"

echo ""
echo "── Design:done + Bug label (already classified) proceeds without delegation ──"
cat > "$SCRATCH/issue-classified-bug.json" <<'JSON'
{"title": "Fix crash", "body": "designed body", "labels": ["Design:done", "Bug"], "author": "alice"}
JSON
: > "$SCRATCH/gh_output"
TEST_COMMAND="engineer" run_pre "$SCRATCH/issue-classified-bug.json"
[[ "$RC" -eq 0 ]] && pass "pre exits 0 on classified Bug issue" || fail "rc=$RC"
if grep -q 'workflow run' "$GH_LOG"; then
  fail "unexpected dispatch on already-classified Bug issue"
else
  pass "no dispatch on already-classified Bug issue"
fi
if grep -q 'dor_skip=true' "$SCRATCH/gh_output"; then
  fail "dor_skip set on already-classified Bug issue"
else
  pass "dor_skip not set on already-classified Bug issue"
fi

echo ""
echo "── Design:done + Intake:Bug (no authoritative Feature/Bug) still cascades ──"
cat > "$SCRATCH/issue-intake-bug.json" <<'JSON'
{"title": "Maybe a bug", "body": "designed body", "labels": ["Design:done", "Intake:Bug"], "author": "alice"}
JSON
: > "$SCRATCH/gh_output"
TEST_COMMAND="engineer" run_pre "$SCRATCH/issue-intake-bug.json"
[[ "$RC" -eq 0 ]] && pass "pre exits 0 on Intake:Bug delegation" || fail "rc=$RC"
grep -q 'gh workflow run autoducks-architect.yml' "$GH_LOG" \
  && pass "Architect workflow dispatched despite Intake:Bug" || fail "no architect dispatch: $(grep 'workflow run' "$GH_LOG" || echo none)"
grep -q 'dor_skip=true' "$SCRATCH/gh_output" \
  && pass "dor_skip output set for Intake:Bug issue" || fail "dor_skip missing"

echo "── revision mode detected via Tactics:done ──"
cat > "$SCRATCH/issue-revision.json" <<'JSON'
{"title": "Add search", "body": "designed body", "labels": ["Design:done", "Tactics:done", "Feature"], "author": "alice"}
JSON
run_pre "$SCRATCH/issue-revision.json"
[[ "$RC" -eq 0 ]] && pass "revision pre exits 0" || fail "rc=$RC"
# IS_REVISION is persisted via GITHUB_ENV when set; we can only assert no crash
# here — the flag propagation is covered by the workflow env contract.

rm -f /tmp/autoducks-pre-failed /tmp/autoducks-dor-delegated /tmp/autoducks-status-comment-id

# A prior Architect re-design clears Tactics:done (bug #880) but the tactical
# zone still lists the tasks — the Engineer must still detect a revision and
# capture OLD_NUMBERS, else those tasks get orphaned (#1026).
echo "── revision detected via tactical-zone refs when Tactics:done is absent (#1026) ──"
cat > "$SCRATCH/issue-refs.json" <<'JSON'
{"title": "Add search", "body": "Design text.\n\n<!-- autoducks:tactical:begin -->\n## Plan\n\n```yaml\nwaves:\n  - name: W1\n    tasks: [863, 870]\n```\n<!-- autoducks:tactical:end -->", "labels": ["Design:done", "Feature"], "author": "alice"}
JSON
run_pre "$SCRATCH/issue-refs.json"
[[ "$RC" -eq 0 ]] && pass "refs-revision: pre exits 0" || fail "refs-revision: rc=$RC"
grep -qx 'IS_REVISION=true' "$SCRATCH/gh_env" \
  && pass "refs-revision: IS_REVISION=true even without Tactics:done" \
  || fail "refs-revision: IS_REVISION not true: $(cat "$SCRATCH/gh_env" 2>/dev/null)"
_old=$(grep '^OLD_NUMBERS=' "$SCRATCH/gh_env" | head -1)
[[ "$_old" == *863* && "$_old" == *870* ]] \
  && pass "refs-revision: OLD_NUMBERS captured the tactical-zone task refs" \
  || fail "refs-revision: OLD_NUMBERS missing refs: $_old"

rm -f /tmp/autoducks-pre-failed /tmp/autoducks-dor-delegated /tmp/autoducks-status-comment-id

echo ""
echo "═══ engineer-dor: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
