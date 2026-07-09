#!/usr/bin/env bash
# Unit tests for progress_labels::clear_review and the rework hand-off's
# clear-then-start sequence: rework/post.sh strips every lingering Review:*
# label the Reviewer mirror-painted on the feature issue + its PR before
# handing off to the Maestro via progress_labels::start. Mirrors the clear
# loop in .autoducks/agents/rework/post.sh (between git::mark_pr_draft and
# progress_labels::start), driven against the real progress-labels.sh helper
# with mocked its::* calls — same style as test/unit-reviewer-mirror.sh.
# Run: bash test/unit-rework-labels.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

LOG=$(mktemp)
reset() { : > "$LOG"; }

# Mocks — its::add_label / its::remove_label (progress-labels.sh). All calls
# are appended to one log for assertion.
its::add_label()    { echo "ADD:$1|$2" >> "$LOG"; }
its::remove_label() { echo "REMOVE:$1|$2" >> "$LOG"; }

export REPO="x/y" RUN_ID="999" AUTODUCKS_AGENT="rework"

# shellcheck source=/dev/null
source "$REPO_ROOT/.autoducks/core/feedback/progress-labels.sh"

# ── clear loop — mirrors rework/post.sh's de-duplicating loop calling
# progress_labels::clear_review over ("$FEATURE_NUM" "$PR_NUM").
clear_review_targets() {
  local feature="$1" pr="$2" _t
  for _t in "$feature" "$pr"; do
    [[ -n "$_t" ]] || continue
    progress_labels::clear_review "$_t"
  done
}

echo "── clear_review: removes all three Review:* labels and nothing else ──"
reset
progress_labels::clear_review "500"
if [[ "$(grep -c '^REMOVE:' "$LOG")" -eq 3 ]]; then
  pass "exactly 3 REMOVE calls"
else
  fail "expected 3 REMOVE calls, got: $(cat "$LOG")"
fi
if grep -q '^REMOVE:500|Review:reviewing$' "$LOG" \
  && grep -q '^REMOVE:500|Review:done$' "$LOG" \
  && grep -q '^REMOVE:500|Review:changes$' "$LOG"; then
  pass "all three Review:* labels removed from #500"
else
  fail "missing expected REMOVE calls: $(cat "$LOG")"
fi
if grep -q '^ADD:' "$LOG"; then
  fail "clear_review issued an ADD: $(cat "$LOG")"
else
  pass "no ADD calls from clear_review"
fi

echo "── clear_review: idempotent when the target has no review labels (mocked failure swallowed) ──"
reset
its::remove_label() { echo "REMOVE:$1|$2" >> "$LOG"; return 1; }
if progress_labels::clear_review "500"; then
  pass "clear_review succeeds even when its::remove_label fails for every label"
else
  fail "clear_review propagated a failure from its::remove_label"
fi
its::remove_label() { echo "REMOVE:$1|$2" >> "$LOG"; }

echo "── clear-then-start: both FEATURE_NUM and PR_NUM are cleared, then FEATURE_NUM gets Work:orchestrating ──"
reset
clear_review_targets "500" "77"
progress_labels::start "500" "Work:orchestrating" "Work:done"
if grep -q '^REMOVE:500|Review:reviewing$' "$LOG" && grep -q '^REMOVE:500|Review:done$' "$LOG" \
  && grep -q '^REMOVE:500|Review:changes$' "$LOG" \
  && grep -q '^REMOVE:77|Review:reviewing$' "$LOG" && grep -q '^REMOVE:77|Review:done$' "$LOG" \
  && grep -q '^REMOVE:77|Review:changes$' "$LOG"; then
  pass "all three Review:* labels removed on both #500 and #77"
else
  fail "REMOVE calls missing on one or both targets: $(cat "$LOG")"
fi
if grep -q '^ADD:500|Work:orchestrating$' "$LOG"; then
  pass "Work:orchestrating added on #500"
else
  fail "Work:orchestrating not added on #500: $(cat "$LOG")"
fi
if grep -q '^ADD:.*Review:' "$LOG"; then
  fail "a residual Review:* ADD leaked through: $(cat "$LOG")"
else
  pass "no residual Review:* ADD"
fi
if grep -q '^ADD:77|' "$LOG"; then
  fail "Work:orchestrating (or any label) was added on #77, not just #500: $(cat "$LOG")"
else
  pass "no ADD on #77 — progress_labels::start only targets FEATURE_NUM"
fi

echo "── clear-then-start: FEATURE_NUM == PR_NUM still clears and starts correctly ──"
reset
clear_review_targets "77" "77"
progress_labels::start "77" "Work:orchestrating" "Work:done"
REMOVE_COUNT=$(grep -c '^REMOVE:77|Review:' "$LOG" || true)
if [[ "$REMOVE_COUNT" -eq 6 ]]; then
  pass "clear_review runs once per (duplicate) target — 3 labels x 2 calls = 6 Review:* REMOVE"
else
  fail "expected 6 Review:* REMOVE calls for the duplicate-target case, got $REMOVE_COUNT: $(cat "$LOG")"
fi
if grep -q '^ADD:77|Work:orchestrating$' "$LOG"; then
  pass "Work:orchestrating added on the shared target"
else
  fail "Work:orchestrating missing on shared target: $(cat "$LOG")"
fi

echo "── clear-then-start: empty FEATURE_NUM/PR_NUM entries are skipped, not painted ──"
reset
clear_review_targets "" "77"
if [[ "$(grep -c '^REMOVE:' "$LOG")" -eq 3 ]] && ! grep -q '^REMOVE:|' "$LOG"; then
  pass "empty target skipped — only #77 cleared"
else
  fail "empty target was not skipped correctly: $(cat "$LOG")"
fi

rm -f "$LOG"

echo ""
echo "═══ rework-labels: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
