#!/usr/bin/env bash
# Unit tests for .autoducks/core/orchestration/review-loop.sh —
# review_loop::iteration / ::decide / ::record, the marker-anchored
# reviewer request-changes round tracker, plus the SHA-less duplicate-event
# fallback review_loop::rework_inflight / ::already_dispatched (Task #1045 /
# ggondim's PR #1038 review, empty-PR_HEAD_SHA case). its::list_comments /
# its::comment_issue / its::update_comment are mocked against an in-memory
# JSON comment store, and its::list_sub_issues / its::get_issue against an
# in-memory sub-issue store, so no network/gh access is needed. Same style as
# test/unit-fold-duplicate.sh and test/unit-delivery-phase.sh.
# Run: bash test/unit-review-loop.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

# ── Fake comment store (JSON array of {id, author, body, created_at, updated_at}) ──
STORE=$(mktemp)
NEXT_ID=1000
reset_store() { echo '[]' > "$STORE"; NEXT_ID=1000; }
reset_store

its::list_comments() {
  cat "$STORE"
}

its::comment_issue() {
  local issue_id="$1" body="$2"
  local id=$NEXT_ID
  NEXT_ID=$((NEXT_ID + 1))
  local tmp; tmp=$(mktemp)
  jq --arg body "$body" --argjson id "$id" \
    '. + [{id: $id, author: "github-actions[bot]", body: $body, created_at: "t0", updated_at: "t0"}]' \
    "$STORE" > "$tmp" && mv "$tmp" "$STORE"
  echo "https://github.com/x/y/issues/$issue_id#issuecomment-$id"
}

its::update_comment() {
  local comment_id="$1" body="$2"
  local tmp; tmp=$(mktemp)
  jq --arg id "$comment_id" --arg body "$body" \
    'map(if (.id | tostring) == $id then .body = $body | .updated_at = "t1" else . end)' \
    "$STORE" > "$tmp" && mv "$tmp" "$STORE"
}

# ── Fake sub-issue store (JSON array of {number, state}) + per-number bodies ──
SUB_STORE=$(mktemp)
SUB_BODIES=$(mktemp)
reset_sub_store() { echo '[]' > "$SUB_STORE"; echo '{}' > "$SUB_BODIES"; }
reset_sub_store

its::list_sub_issues() {
  cat "$SUB_STORE"
}

its::get_issue() {
  local issue_id="$1"
  local body
  body=$(jq -r --arg n "$issue_id" '.[$n] // ""' "$SUB_BODIES")
  jq -n --arg body "$body" '{title: "", body: $body, labels: [], author: "bot"}'
}

# seed_sub_issue NUM STATE BODY
seed_sub_issue() {
  local tmp; tmp=$(mktemp)
  jq --arg n "$1" --arg s "$2" '. + [{number: ($n | tonumber), title: "rework", state: $s}]' \
    "$SUB_STORE" > "$tmp" && mv "$tmp" "$SUB_STORE"
  tmp=$(mktemp)
  jq --arg n "$1" --arg b "$3" '. + {($n): $b}' "$SUB_BODIES" > "$tmp" && mv "$tmp" "$SUB_BODIES"
}

# shellcheck source=/dev/null
source "$REPO_ROOT/.autoducks/core/orchestration/review-loop.sh"

echo "── review_loop::iteration ──"
reset_store
if [[ "$(review_loop::iteration 42 7)" == "0" ]]; then
  pass "echoes 0 when no marker comment exists"
else
  fail "expected 0 for no marker, got: $(review_loop::iteration 42 7)"
fi

review_loop::record 42 7 1
if [[ "$(review_loop::iteration 42 7)" == "1" ]]; then
  pass "echoes recorded N after review_loop::record has run"
else
  fail "expected 1 after record, got: $(review_loop::iteration 42 7)"
fi

echo "── review_loop::iteration: feature/pr scoping ──"
reset_store
review_loop::record 42 7 2
if [[ "$(review_loop::iteration 42 99)" == "0" ]]; then
  pass "a marker for a different PR is not matched"
else
  fail "cross-PR marker leaked: $(review_loop::iteration 42 99)"
fi
if [[ "$(review_loop::iteration 1 7)" == "0" ]]; then
  pass "a marker for a different feature is not matched"
else
  fail "cross-feature marker leaked: $(review_loop::iteration 1 7)"
fi

echo "── review_loop::decide ──"
check_decide() { # label verdict iteration max expected
  local got
  got=$(review_loop::decide "$2" "$3" "$4")
  if [[ "$got" == "$5" ]]; then
    pass "$1"
  else
    fail "$1 — expected $5, got $got"
  fi
}
check_decide "request-changes, rounds left → continue" request-changes 0 3 continue
check_decide "request-changes, at cap → stop-blocked-max" request-changes 3 3 stop-blocked-max
check_decide "request-changes, over cap → stop-blocked-max" request-changes 4 3 stop-blocked-max
check_decide "approve → stop-approved" approve 0 3 stop-approved
check_decide "comment → stop-approved" comment 0 3 stop-approved
check_decide "garbage verdict → stop-approved (non-blocking)" some-garbage 0 3 stop-approved

echo "── review_loop::record: idempotent edit-in-place ──"
reset_store
review_loop::record 42 7 1
review_loop::record 42 7 1
COUNT=$(jq 'length' "$STORE")
if [[ "$COUNT" -eq 1 ]]; then
  pass "running record twice yields exactly one marker comment"
else
  fail "expected 1 comment, got $COUNT: $(cat "$STORE")"
fi
if [[ "$(review_loop::iteration 42 7)" == "1" ]]; then
  pass "marker still reads iteration=1 after the idempotent re-run"
else
  fail "expected iteration=1, got: $(review_loop::iteration 42 7)"
fi

echo "── review_loop::record: advances existing marker in place, no duplicate ──"
reset_store
review_loop::record 42 7 1
review_loop::record 42 7 2
COUNT=$(jq 'length' "$STORE")
if [[ "$COUNT" -eq 1 ]]; then
  pass "advancing the round edits the same comment (still 1 comment)"
else
  fail "expected 1 comment after advancing, got $COUNT: $(cat "$STORE")"
fi
if [[ "$(review_loop::iteration 42 7)" == "2" ]]; then
  pass "iteration advances to 2 in place"
else
  fail "expected iteration=2, got: $(review_loop::iteration 42 7)"
fi

echo "── review_loop::record: max defaults ──"
reset_store
review_loop::record 42 7 1
BODY=$(jq -r '.[0].body' "$STORE")
if [[ "$BODY" == *"max=3"* ]]; then
  pass "max defaults to 3 when never specified"
else
  fail "expected default max=3 in marker, got: $BODY"
fi

review_loop::record 42 7 2 5
BODY=$(jq -r '.[0].body' "$STORE")
if [[ "$BODY" == *"iteration=2"* && "$BODY" == *"max=5"* ]]; then
  pass "explicit max overrides the default and is preserved in the marker"
else
  fail "expected iteration=2 max=5 in marker, got: $BODY"
fi

review_loop::record 42 7 3
BODY=$(jq -r '.[0].body' "$STORE")
if [[ "$BODY" == *"iteration=3"* && "$BODY" == *"max=5"* ]]; then
  pass "omitting max on a later call inherits the prior marker's max"
else
  fail "expected iteration=3 max=5 (inherited) in marker, got: $BODY"
fi

rm -f "$STORE"

echo "── review_loop::rework_inflight ──"
reset_sub_store
if ! review_loop::rework_inflight 42; then
  pass "false when there are no sub-issues at all"
else
  fail "expected false with no sub-issues"
fi

seed_sub_issue 900 closed "<!-- autoducks:rework: feature=42 pr=7 since=t0 -->"
if ! review_loop::rework_inflight 42; then
  pass "false when the only matching sub-issue is closed"
else
  fail "expected false for a closed-only match"
fi

seed_sub_issue 901 open "<!-- autoducks:rework: feature=42 pr=7 since=t0 -->"
if review_loop::rework_inflight 42; then
  pass "true when an open sub-issue carries the feature's rework marker"
else
  fail "expected true with an open matching sub-issue"
fi

reset_sub_store
seed_sub_issue 902 open "<!-- autoducks:rework: feature=99 pr=7 since=t0 -->"
if ! review_loop::rework_inflight 42; then
  pass "false when the open sub-issue belongs to a different feature"
else
  fail "cross-feature rework sub-issue leaked"
fi

echo "── review_loop::already_dispatched ──"
reset_store
reset_sub_store
if ! review_loop::already_dispatched 42 7 0; then
  pass "false on a genuinely first round (no marker ahead, no rework in flight)"
else
  fail "expected false for a legitimate first round"
fi

reset_store
review_loop::record 42 7 1
if review_loop::already_dispatched 42 7 0; then
  pass "true when the marker already recorded the round this call would record"
else
  fail "expected true when the marker is already at iteration+1"
fi

reset_store
reset_sub_store
seed_sub_issue 903 open "<!-- autoducks:rework: feature=42 pr=7 since=t0 -->"
if review_loop::already_dispatched 42 7 0; then
  pass "true when an in-flight rework sub-issue exists, even with the marker untouched"
else
  fail "expected true via the rework-sub-issue fallback"
fi

rm -f "$SUB_STORE" "$SUB_BODIES"

echo ""
echo "═══ review-loop: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
