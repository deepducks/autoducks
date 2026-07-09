#!/usr/bin/env bash
# Unit tests for orchestrator_comment::upsert in
# .autoducks/core/feedback/status-comment.sh
# Run: bash test/unit-orchestrator-comment.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

CID_FILE="/tmp/autoducks-maestro-comment-id"
LOG=$(mktemp)
LIST_RESPONSE_FILE=$(mktemp)
echo "[]" > "$LIST_RESPONSE_FILE"

reset() {
  : > "$LOG"
  rm -f "$CID_FILE"
  echo "[]" > "$LIST_RESPONSE_FILE"
}

NEXT_COMMENT_ID=100001

# Mocks — its::list_comments, its::update_comment, its::comment_issue
its::list_comments() {
  echo "LIST:$*" >> "$LOG"
  cat "$LIST_RESPONSE_FILE"
}
its::update_comment() {
  echo "UPDATE:$1|$2" >> "$LOG"
}
its::comment_issue() {
  echo "COMMENT:$1|$2" >> "$LOG"
  echo "https://github.com/x/y/issues/$1#issuecomment-${NEXT_COMMENT_ID}"
}

export REPO="x/y"

# shellcheck source=/dev/null
source "$REPO_ROOT/.autoducks/core/feedback/status-comment.sh"

echo "── first call: no cache, no matching comment ──"
reset
export FEATURE="42"
NEXT_COMMENT_ID=555111
orchestrator_comment::upsert 42 "🌊 wave 1 running"

if grep -q 'COMMENT:42|' "$LOG"; then
  pass "posted a new comment"
else
  fail "no comment posted: $(cat "$LOG")"
fi
if [[ "$(tail -1 "$LOG")" == "<!-- autoducks:maestro-status:42 -->" ]]; then
  pass "posted body ends with the per-feature marker"
else
  fail "marker not at end of body: $(cat "$LOG")"
fi
if [[ -s "$CID_FILE" && "$(cat "$CID_FILE")" == "555111" ]]; then
  pass "new comment id cached"
else
  fail "cache not written: $(cat "$CID_FILE" 2>/dev/null || echo missing)"
fi

echo "── second call: cache present → PATCH, no new post ──"
: > "$LOG"
orchestrator_comment::upsert 42 "🌊 wave 2 running"
if grep -q 'UPDATE:555111|' "$LOG"; then
  pass "edited the cached comment in place"
else
  fail "no PATCH recorded: $(cat "$LOG")"
fi
if grep -q 'COMMENT:' "$LOG"; then
  fail "posted a NEW comment when cache was present"
else
  pass "no duplicate post while cache present"
fi

echo "── third call: cache cleared, marker present in list_comments → rediscover ──"
: > "$LOG"
rm -f "$CID_FILE"
cat > "$LIST_RESPONSE_FILE" <<'EOF'
[
  {"id": 555111, "author": "github-actions[bot]", "body": "🌊 wave 2 running\n<!-- autoducks:maestro-status:42 -->", "created_at": "2026-07-08T00:00:00Z", "updated_at": "2026-07-08T00:01:00Z"}
]
EOF
orchestrator_comment::upsert 42 "🌊 wave 3 running"
if grep -q 'LIST:42' "$LOG"; then
  pass "scanned list_comments since cache was empty"
else
  fail "did not scan comments: $(cat "$LOG")"
fi
if grep -q 'UPDATE:555111|' "$LOG"; then
  pass "rediscovered the existing comment by marker and edited it"
else
  fail "did not edit the rediscovered comment: $(cat "$LOG")"
fi
if grep -q 'COMMENT:' "$LOG"; then
  fail "posted a duplicate comment instead of rediscovering"
else
  pass "no duplicate post after rediscovery"
fi
if [[ -s "$CID_FILE" && "$(cat "$CID_FILE")" == "555111" ]]; then
  pass "rediscovered id re-cached"
else
  fail "rediscovered id not cached: $(cat "$CID_FILE" 2>/dev/null || echo missing)"
fi

echo "── feature isolation: feature B never edits feature A's comment ──"
: > "$LOG"
rm -f "$CID_FILE"
# list_comments still only contains feature A's (id=42) marker comment.
export FEATURE="43"
NEXT_COMMENT_ID=555222
orchestrator_comment::upsert 43 "🌊 wave 1 running"
if grep -q 'UPDATE:555111|' "$LOG"; then
  fail "feature B edited feature A's comment"
else
  pass "feature B did not touch feature A's comment"
fi
if grep -q 'COMMENT:43|' "$LOG"; then
  pass "feature B posted its own new comment"
else
  fail "feature B did not post: $(cat "$LOG")"
fi
if [[ "$(tail -1 "$LOG")" == "<!-- autoducks:maestro-status:43 -->" ]]; then
  pass "feature B's comment carries feature B's marker"
else
  fail "feature B's marker missing/wrong: $(cat "$LOG")"
fi
if [[ -s "$CID_FILE" && "$(cat "$CID_FILE")" == "555222" ]]; then
  pass "feature B's new id cached separately"
else
  fail "feature B id not cached: $(cat "$CID_FILE" 2>/dev/null || echo missing)"
fi

echo "── failure paths never abort under set -e ──"
reset
export FEATURE="42"
its::list_comments() { echo "LIST:$*" >> "$LOG"; return 1; }
its::comment_issue() { echo "COMMENT:$*" >> "$LOG"; return 1; }
(
  set -e
  orchestrator_comment::upsert 42 "🌊 wave running"
  echo "SURVIVED_LIST_AND_POST" >> "$LOG"
)
grep -q "SURVIVED_LIST_AND_POST" "$LOG" && pass "list/POST failures don't abort under set -e" || fail "aborted under set -e (list/post)"

reset
echo "555111" > "$CID_FILE"
its::update_comment() { echo "UPDATE:$1|$2" >> "$LOG"; return 1; }
(
  set -e
  orchestrator_comment::upsert 42 "🌊 wave running"
  echo "SURVIVED_PATCH" >> "$LOG"
)
grep -q "SURVIVED_PATCH" "$LOG" && pass "PATCH failure doesn't abort under set -e" || fail "aborted under set -e (patch)"

rm -f "$LOG" "$LIST_RESPONSE_FILE" "$CID_FILE"
unset FEATURE

echo ""
echo "═══ orchestrator-comment: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
