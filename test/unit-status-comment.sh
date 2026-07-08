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
reset() { : > "$LOG"; rm -f /tmp/autoducks-status-comment-id; }

# Mocks — gh (for the initial post), its::update_comment, its::comment_issue
gh() {
  # `gh issue comment N --repo R --body B` → print a comment URL like the CLI
  echo "GH:$*" >> "$LOG"
  echo "https://github.com/x/y/issues/42#issuecomment-123456"
}
its::update_comment() { echo "UPDATE:$1|$2" >> "$LOG"; }
its::comment_issue()  { echo "COMMENT:$1|$2" >> "$LOG"; }

export REPO="x/y" RUN_ID="999" AUTODUCKS_AGENT="architect"

# shellcheck source=/dev/null
source "$REPO_ROOT/.autoducks/core/feedback/status-comment.sh"

echo "── start ──"
reset
status_comment::start 42
if [[ -s /tmp/autoducks-status-comment-id && "$(cat /tmp/autoducks-status-comment-id)" == "123456" ]]; then
  pass "comment id captured from gh URL"
else
  fail "id file: $(cat /tmp/autoducks-status-comment-id 2>/dev/null || echo missing)"
fi
grep -q 'GH:issue comment 42' "$LOG" && pass "posted on the right issue" || fail "no post recorded"
grep -q 'Architect' "$LOG" && pass "friendly agent label used" || fail "label missing"
grep -q 'running on' "$LOG" && pass "running headline present" || fail "headline missing"
grep -q 'actions/runs/999' "$LOG" && pass "workflow run link present" || fail "run link missing"
grep -q 'loading.gif' "$LOG" && pass "spinner gif referenced" || fail "gif missing"
grep -q 'width="24"' "$LOG" && pass "spinner width is 24" || fail "spinner width missing/wrong"

echo "── finish edits in place ──"
reset
status_comment::start 42
status_comment::finish 42 "All done details"
if grep -q 'UPDATE:123456|✅' "$LOG"; then
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
grep -q 'UPDATE:123456|⚠️' "$LOG" && pass "fail edits with ⚠️" || fail "no fail update"

echo "── delegate edits in place ──"
reset
status_comment::start 42
status_comment::delegate 42 "handed off"
grep -q 'UPDATE:123456|🔁' "$LOG" && pass "delegate edits with 🔁" || fail "no delegate update"

echo "── fallback: no status comment owned ──"
reset
status_comment::finish 42 "orphan finish"
if grep -q 'COMMENT:42|✅' "$LOG"; then
  pass "finish without start falls back to a fresh comment"
else
  fail "no fallback comment: $(cat "$LOG")"
fi

echo "── agent label mapping ──"
for pair in "engineer Engineer" "maestro Maestro" "developer Developer" "fix Fix"; do
  a="${pair%% *}"; want="${pair##* }"
  got=$(AUTODUCKS_AGENT="$a" status_comment::_label)
  [[ "$got" == "$want" ]] && pass "$a → $want" || fail "$a → $got"
done

rm -f "$LOG" /tmp/autoducks-status-comment-id

echo ""
echo "═══ status-comment: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
