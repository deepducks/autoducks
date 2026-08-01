#!/usr/bin/env bash
# Unit tests for .autoducks/core/feedback/status-comment.sh
# Run: bash test/unit-status-comment.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

LOG=$(mktemp)
reset() { : > "$LOG"; rm -f /tmp/autoducks-status-comment-id.42; }

# Mocks — gh (for the initial post), its::update_comment, its::comment_issue
gh() {
  # `gh issue comment N --repo R --body B` → print a comment URL like the CLI
  echo "GH:$*" >> "$LOG"
  local issue_num="$3"
  echo "https://github.com/x/y/issues/${issue_num}#issuecomment-1${issue_num}"
}
its::update_comment() { echo "UPDATE:$1|$2" >> "$LOG"; }
its::comment_issue()  { echo "COMMENT:$1|$2" >> "$LOG"; }

export REPO="x/y" RUN_ID="999" AUTODUCKS_AGENT="architect"

# shellcheck source=/dev/null
source "$REPO_ROOT/.autoducks/core/feedback/status-comment.sh"

echo "── start ──"
reset
status_comment::start 42
if [[ -s /tmp/autoducks-status-comment-id.42 && "$(cat /tmp/autoducks-status-comment-id.42)" == "142" ]]; then
  pass "comment id captured from gh URL"
else
  fail "id file: $(cat /tmp/autoducks-status-comment-id.42 2>/dev/null || echo missing)"
fi
grep -q 'GH:issue comment 42' "$LOG" && pass "posted on the right issue" || fail "no post recorded"
grep -q 'Architect' "$LOG" && pass "friendly agent label used" || fail "label missing"
grep -q 'running on' "$LOG" && pass "running headline present" || fail "headline missing"
grep -q 'actions/runs/999' "$LOG" && pass "workflow run link present" || fail "run link missing"
grep -q 'loading.gif' "$LOG" && pass "spinner gif referenced" || fail "gif missing"
grep -q 'height="32" valign="middle"' "$LOG" && pass "spinner sized height=32 valign=middle" || fail "spinner sizing missing/wrong"

echo "── finish edits in place ──"
reset
status_comment::start 42
status_comment::finish 42 "All done details"
if grep -q 'UPDATE:142|✅' "$LOG"; then
  pass "finish edits the SAME comment with ✅"
else
  fail "no in-place update: $(grep UPDATE "$LOG" || echo none)"
fi
grep -q 'All done details' "$LOG" && pass "details included" || fail "details missing"
if grep -q 'COMMENT:' "$LOG"; then fail "finish posted a NEW comment (should edit)"; else pass "no extra comment posted"; fi

echo "── fail edits in place ──"
reset
status_comment::start 42
status_comment::fail 42
grep -q 'UPDATE:142|⚠️' "$LOG" && pass "fail edits with ⚠️" || fail "no fail update"

echo "── delegate edits in place ──"
reset
status_comment::start 42
status_comment::delegate 42 "handed off"
grep -q 'UPDATE:142|🔁' "$LOG" && pass "delegate edits with 🔁" || fail "no delegate update"

echo "── fallback: no status comment owned ──"
reset
status_comment::finish 42 "orphan finish"
if grep -q 'COMMENT:42|✅' "$LOG"; then
  pass "finish without start falls back to a fresh comment"
else
  fail "no fallback comment: $(cat "$LOG")"
fi

echo "── agent label mapping ──"
for pair in "engineer Engineer" "maestro Maestro" "developer Developer" "fix Fix" "reviewer Reviewer" "rework Rework" "defer Defer"; do
  a="${pair%% *}"; want="${pair##* }"
  got=$(AUTODUCKS_AGENT="$a" status_comment::_label)
  [[ "$got" == "$want" ]] && pass "$a → $want" || fail "$a → $got"
done

echo "── two-target independence ──"
reset
rm -f /tmp/autoducks-status-comment-id.99
status_comment::start 42
status_comment::start 99
status_comment::finish 42 "target 42 done"
status_comment::finish 99 "target 99 done"
if grep -q 'UPDATE:142|✅' "$LOG" && grep -q 'UPDATE:199|✅' "$LOG"; then
  pass "finish 42 and finish 99 edit independent comments"
else
  fail "cross-target clobber: $(grep UPDATE "$LOG" || echo none)"
fi
rm -f /tmp/autoducks-status-comment-id.99

rm -f "$LOG" /tmp/autoducks-status-comment-id.42 /tmp/autoducks-status-comment-id.99

echo "── product/post.sh: JOB_STATUS=cancelled gate ──"
# End-to-end: run the real script (mocked `gh` on PATH, same shim convention
# as test/unit-architect-guard.sh) so the cancellation gate is exercised in
# its actual position — after the ERR trap / pre-failure marker, before the
# validator — rather than just unit-testing cancellation::handle in isolation.
SCRATCH="$(mktemp -d)"
mkdir -p "$SCRATCH/bin"
cat > "$SCRATCH/bin/gh" <<'SHIM'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"
case "$1 $2" in
  "issue comment") echo "https://github.com/x/y/issues/55#issuecomment-1" ;;
  *) : ;;
esac
exit 0
SHIM
chmod +x "$SCRATCH/bin/gh"

GH_LOG="$SCRATCH/gh.log"
: > "$GH_LOG"
SUMMARY_FILE="$SCRATCH/step-summary.md"
: > "$SUMMARY_FILE"
rm -rf /tmp/autoducks-local
rm -f /tmp/autoducks-status-comment-id.55
# No /tmp/triage-decisions.json is provided — if the cancellation gate were
# skipped, the run would fall through to the validator and fail there,
# proving the gate (not a missing fixture) is what short-circuits the run.

RC=0
(
  PATH="$SCRATCH/bin:$PATH" \
  GITHUB_ACTIONS=true \
  GH_LOG="$GH_LOG" \
  JOB_STATUS=cancelled \
  ISSUE_NUM=55 REPO=x/y RUN_ID=999 COMMENT_ID=555 COMMENTER=alice \
  GITHUB_STEP_SUMMARY="$SUMMARY_FILE" \
  GH_TOKEN=t \
  bash "$REPO_ROOT/.autoducks/agents/product/post.sh"
) >/dev/null 2>&1 || RC=$?

[[ "$RC" -eq 0 ]] && pass "cancelled run exits 0" || fail "cancelled run rc=$RC"
grep -q '🚫' "$GH_LOG" && pass "status_comment::cancel posted (🚫)" || fail "no cancel comment: $(cat "$GH_LOG")"
grep -q 'cancelled on' "$GH_LOG" && pass "cancel headline present" || fail "cancel headline missing"
if grep -q '⚠️' "$GH_LOG"; then
  fail "a failure comment (⚠️) was posted on a cancelled run: $(cat "$GH_LOG")"
else
  pass "no notify_failure / narrate_fail (⚠️) comment posted"
fi
if grep -q 'triage run failed' "$SUMMARY_FILE"; then
  fail "job-summary 'triage run failed' text leaked onto a cancelled run"
else
  pass "no job-summary 'triage run failed' entry"
fi
if grep -q 'content=confused' "$GH_LOG"; then
  fail "😕 confused reaction fired on a cancelled run"
else
  pass "no confused reaction"
fi

rm -rf "$SCRATCH" /tmp/autoducks-local /tmp/autoducks-status-comment-id.55

# ---------------------------------------------------------------------------
echo ""
echo "── delegate posts a terminal reaction (#180) ──"

# Every delegation path exits right after this call without doing agent work, so
# if delegate does not move the reaction, nothing does: the trigger comment stays
# on the 👀 set at dispatch and every watcher of the 👀 → 👍/😕 contract reads a
# finished run as hung. Seven call sites had forgotten it, which is why the
# reaction lives in the shared function rather than in each of them.
#
# 🚀 and not 👍: the first cut of this fix used +1 and smoke-test-plan.sh caught
# it immediately, asserting a plan that nobody had written yet. A handoff is a
# third terminal state for this comment — the run is over, the work is not.
DLOG=$(mktemp)
trap 'rm -f "$DLOG"' EXIT

react_to_comment() { echo "REACT:$1:$2" >> "$DLOG"; }
status_comment::_label() { echo "engineer"; }
status_comment::_run_link() { echo "[run](x)"; }
status_comment::_edit() { echo "EDIT:$2" >> "$DLOG"; }

# shellcheck source=/dev/null
COMMENT_ID=4242
source "$REPO_ROOT/.autoducks/core/feedback/status-comment.sh" 2>/dev/null || true
# Re-stub: sourcing the module redefines the internals above.
status_comment::_label() { echo "engineer"; }
status_comment::_run_link() { echo "[run](x)"; }
status_comment::_edit() { echo "EDIT:$2" >> "$DLOG"; }

: > "$DLOG"
status_comment::delegate 42 "Architect dispatched first."

if grep -q 'REACT:4242:rocket' "$DLOG"; then
  pass "delegate reacts 🚀 (handoff, not success) on the trigger comment"
else
  fail "delegate posted no handoff reaction: $(tr '\n' ' ' < "$DLOG")"
fi
if grep -q 'EDIT:.*delegated' "$DLOG"; then
  pass "delegate still edits the status comment"
else
  fail "delegate stopped editing the status comment"
fi

# Must not explode where react_to_comment was never sourced — status-comment.sh
# is loaded in contexts that do not pull the reaction helper.
unset -f react_to_comment
: > "$DLOG"
if status_comment::delegate 42 "no reaction helper here" 2>/dev/null; then
  pass "delegate survives without react_to_comment loaded"
else
  fail "delegate failed when react_to_comment was absent"
fi
if grep -q 'EDIT:.*delegated' "$DLOG"; then
  pass "and still posts the status comment in that case"
else
  fail "the status comment was lost when react_to_comment was absent"
fi

echo ""
echo "═══ status-comment: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
