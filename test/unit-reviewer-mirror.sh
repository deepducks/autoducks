#!/usr/bin/env bash
# Unit tests for the Reviewer's mirror behavior: REVIEW_TARGETS is built from
# (FEATURE_NUM, PR_NUM), both targets get painted with a Review:reviewing
# label + a "Running…" status comment, and a verdict swaps the label on both.
# Mirrors the REVIEW_TARGETS build/paint loop in
# .autoducks/agents/reviewer/pre.sh and the verdict → done_label swap loop in
# .autoducks/agents/reviewer/post.sh, driven against the real
# progress-labels.sh/status-comment.sh helpers with mocked gh/its::* calls —
# same style as test/unit-status-comment.sh and test/unit-notify-failure.sh.
# Run: bash test/unit-reviewer-mirror.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

LOG=$(mktemp)
reset() { : > "$LOG"; rm -f /tmp/autoducks-status-comment-id.500 /tmp/autoducks-status-comment-id.77; }

# Mocks — gh (status_comment::start's initial post), its::update_comment /
# its::comment_issue (status-comment.sh), its::add_label / its::remove_label
# (progress-labels.sh). All calls are appended to one log for assertion.
gh() {
  echo "GH:$*" >> "$LOG"
  local issue_num="$3"
  echo "https://github.com/x/y/issues/${issue_num}#issuecomment-1${issue_num}"
}
its::update_comment() { echo "UPDATE:$1|$2" >> "$LOG"; }
its::comment_issue()  { echo "COMMENT:$1|$2" >> "$LOG"; }
its::add_label()      { echo "ADD:$1|$2" >> "$LOG"; }
its::remove_label()   { echo "REMOVE:$1|$2" >> "$LOG"; }

export REPO="x/y" RUN_ID="999" AUTODUCKS_AGENT="reviewer"

# shellcheck source=/dev/null
source "$REPO_ROOT/.autoducks/core/feedback/progress-labels.sh"
# shellcheck source=/dev/null
source "$REPO_ROOT/.autoducks/core/feedback/status-comment.sh"

# ── REVIEW_TARGETS build — mirrors reviewer/pre.sh's de-duplicating loop
# building REVIEW_TARGETS from ("$FEATURE_NUM" "$PR_NUM").
build_review_targets() {
  local feature="$1" pr="$2"
  REVIEW_TARGETS=()
  local _t
  for _t in "$feature" "$pr"; do
    [[ -n "$_t" ]] || continue
    [[ " ${REVIEW_TARGETS[*]-} " == *" $_t "* ]] && continue
    REVIEW_TARGETS+=("$_t")
  done
}

# ── paint loop — mirrors reviewer/pre.sh's status_comment::start +
# progress_labels::start over every REVIEW_TARGETS entry.
paint_review_targets() {
  local _t
  for _t in "${REVIEW_TARGETS[@]}"; do
    status_comment::start "$_t"
    progress_labels::start "$_t" "Review:reviewing" "Review:done"
  done
}

# ── verdict swap — mirrors reviewer/post.sh's done_label selection plus the
# progress_labels::finish / status_comment::finish loops over REVIEW_TARGETS.
finish_review_targets() {
  local verdict="$1" done_label
  if [[ "$verdict" == "request-changes" ]]; then
    done_label="Review:changes"
  else
    done_label="Review:done"
  fi
  local _t
  for _t in "${REVIEW_TARGETS[@]}"; do
    progress_labels::finish "$_t" "Review:reviewing" "$done_label"
  done
  for _t in "${REVIEW_TARGETS[@]}"; do
    status_comment::finish "$_t" "verdict: $verdict"
  done
}

echo "── build: two distinct targets (feature issue + PR) ──"
reset
build_review_targets "500" "77"
if [[ "${#REVIEW_TARGETS[@]}" -eq 2 && "${REVIEW_TARGETS[0]}" == "500" && "${REVIEW_TARGETS[1]}" == "77" ]]; then
  pass "REVIEW_TARGETS = (feature, pr)"
else
  fail "REVIEW_TARGETS: ${REVIEW_TARGETS[*]-}"
fi

echo "── build: de-dupes when feature == PR (triggered from the PR itself) ──"
reset
build_review_targets "77" "77"
if [[ "${#REVIEW_TARGETS[@]}" -eq 1 && "${REVIEW_TARGETS[0]}" == "77" ]]; then
  pass "duplicate collapses to a single target"
else
  fail "REVIEW_TARGETS: ${REVIEW_TARGETS[*]-}"
fi

echo "── build: empty FEATURE_NUM degrades to a single PR-only target ──"
reset
build_review_targets "" "77"
if [[ "${#REVIEW_TARGETS[@]}" -eq 1 && "${REVIEW_TARGETS[0]}" == "77" ]]; then
  pass "empty feature number dropped, PR-only target remains"
else
  fail "REVIEW_TARGETS: ${REVIEW_TARGETS[*]-}"
fi

echo "── paint: both targets get a Review:reviewing label + Running… comment ──"
reset
build_review_targets "500" "77"
paint_review_targets
if grep -q 'ADD:500|Review:reviewing' "$LOG" && grep -q 'ADD:77|Review:reviewing' "$LOG"; then
  pass "Review:reviewing added on both #500 and #77"
else
  fail "label add missing: $(cat "$LOG")"
fi
if grep -q 'GH:issue comment 500' "$LOG" && grep -q 'GH:issue comment 77' "$LOG"; then
  pass "Running… status comment posted on both #500 and #77"
else
  fail "status comment missing: $(cat "$LOG")"
fi

echo "── paint: single-target set (empty FEATURE_NUM) paints the PR only ──"
reset
build_review_targets "" "77"
paint_review_targets
ADD_CALLS=$(grep -c '^ADD:' "$LOG" || true)
GH_CALLS=$(grep -c '^GH:' "$LOG" || true)
if [[ "$ADD_CALLS" -eq 1 && "$GH_CALLS" -eq 1 ]]; then
  pass "exactly one label-add and one status comment for the single-target set"
else
  fail "expected 1 ADD + 1 GH call, got ADD=$ADD_CALLS GH=$GH_CALLS: $(cat "$LOG")"
fi
if grep -q '^ADD:77|Review:reviewing' "$LOG" && grep -q 'GH:issue comment 77' "$LOG"; then
  pass "the single call targets the PR, not an empty string"
else
  fail "single call did not target #77: $(cat "$LOG")"
fi
if grep -q '^ADD:|' "$LOG" || grep -q 'GH:issue comment  ' "$LOG"; then
  fail "an empty-string target was painted: $(cat "$LOG")"
else
  pass "no empty-string label/comment call"
fi

echo "── verdict: request-changes swaps the label to Review:changes on both targets ──"
reset
build_review_targets "500" "77"
paint_review_targets
: > "$LOG"   # isolate the finish assertions from the paint calls above
finish_review_targets "request-changes"
if grep -q 'REMOVE:500|Review:reviewing' "$LOG" && grep -q 'REMOVE:77|Review:reviewing' "$LOG"; then
  pass "Review:reviewing removed on both targets"
else
  fail "label remove missing: $(cat "$LOG")"
fi
if grep -q 'ADD:500|Review:changes' "$LOG" && grep -q 'ADD:77|Review:changes' "$LOG"; then
  pass "Review:changes added on both targets"
else
  fail "Review:changes not added on both: $(cat "$LOG")"
fi
if grep -q 'UPDATE:1500|✅' "$LOG" && grep -q 'UPDATE:177|✅' "$LOG"; then
  pass "finish status comment edited in place on both targets"
else
  fail "status comment finish missing: $(cat "$LOG")"
fi

echo "── verdict: approve/comment swap the label to Review:done on both targets ──"
for v in approve comment; do
  reset
  build_review_targets "500" "77"
  paint_review_targets
  : > "$LOG"
  finish_review_targets "$v"
  if grep -q 'ADD:500|Review:done' "$LOG" && grep -q 'ADD:77|Review:done' "$LOG"; then
    pass "$v: Review:done added on both targets"
  else
    fail "$v: Review:done not added on both: $(cat "$LOG")"
  fi
done

rm -f "$LOG" /tmp/autoducks-status-comment-id.500 /tmp/autoducks-status-comment-id.77

echo ""
echo "═══ reviewer-mirror: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
