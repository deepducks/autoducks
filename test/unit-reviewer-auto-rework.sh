#!/usr/bin/env bash
# Unit tests for the bounded self-continuing review loop wired into
# .autoducks/agents/reviewer/post.sh (Task #1030): on a request-changes
# verdict with review.auto_rework left at its default (true), the reviewer
# auto-dispatches a rework round via git::dispatch_workflow and advances the
# review-loop marker instead of waiting on a human /rework; once the marker's
# round hits review.max_iterations it stops dispatching and hands off to a
# human instead; and an explicit auto_rework:false restores that human-handoff
# path unconditionally. Also covers the Idempotency guard: a duplicate
# request-changes run for the same PR_HEAD_SHA (a retried ready_for_review
# event / manual re-trigger) must not double-dispatch or double-increment
# the review-loop marker, while a genuinely new round (different
# PR_HEAD_SHA) still advances normally (Task #1043 / ggondim's PR #1038
# review Finding #2).
#
# Runs the real reviewer/post.sh as a subprocess with `gh` shimmed out (same
# technique as test/unit-reviewer-max-turns.sh), pointed at a scratch
# AUTODUCKS_ROOT (symlinking the repo's real core/providers/agents, own
# autoducks.json) so review.auto_rework / review.max_iterations can be varied
# per case without touching the repo's real config — same scratch-root trick
# as test/unit-review-config-clamp.sh. The gh shim backs its::list_comments /
# its::comment_issue / its::update_comment with an in-memory JSON comment
# store, so review_loop::iteration/::record round-trip for real.
# Run: bash test/unit-reviewer-auto-rework.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POST_SH="$REPO_ROOT/.autoducks/agents/reviewer/post.sh"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

REPO_NAME="acme/widgets"
GH_LOG="$SCRATCH/gh.log"
BODIES_LOG="$SCRATCH/bodies.log"
COMMENTS_STORE="$SCRATCH/comments.json"
NEXT_ID_FILE="$SCRATCH/next_id"

# ── Scratch AUTODUCKS_ROOT: symlink the real tree, own autoducks.json ───────
CONFIG_ROOT="$SCRATCH/autoducks-root"
mkdir -p "$CONFIG_ROOT"
ln -s "$REPO_ROOT/.autoducks/agents" "$CONFIG_ROOT/agents"
ln -s "$REPO_ROOT/.autoducks/core" "$CONFIG_ROOT/core"
ln -s "$REPO_ROOT/.autoducks/providers" "$CONFIG_ROOT/providers"
ln -s "$REPO_ROOT/.autoducks/security-guidelines.md" "$CONFIG_ROOT/security-guidelines.md"

# write_config REVIEW_JSON — same fixed scaffolding as
# test/unit-review-config-clamp.sh, varying only the `.review` block.
write_config() {
  cat > "$CONFIG_ROOT/autoducks.json" <<EOF
{
  "providers": {"its": "github", "git": "github", "llm": "claude"},
  "defaults": {"model": "m", "effort": "high", "base_branch": "main", "merge_method": "auto"},
  "review": $1
}
EOF
}

mkdir -p "$SCRATCH/bin"
cat > "$SCRATCH/bin/gh" <<'SHIM'
#!/usr/bin/env bash
echo "CALL: $*" >> "$GH_LOG"

if [[ "$1" == "issue" && "$2" == "comment" ]]; then
  issue="$3"
  body="" prev=""
  for a in "$@"; do
    [[ "$prev" == "--body" ]] && body="$a"
    prev="$a"
  done
  id=$(cat "$NEXT_ID_FILE"); echo $((id + 1)) > "$NEXT_ID_FILE"
  tmp=$(mktemp)
  jq --arg body "$body" --argjson id "$id" \
    '. + [{id: $id, author: "github-actions[bot]", body: $body, created_at: "t0", updated_at: "t0"}]' \
    "$COMMENTS_STORE" > "$tmp" && mv "$tmp" "$COMMENTS_STORE"
  echo "COMMENT_ISSUE:$issue:$id" >> "$GH_LOG"
  printf '%s\n---\n' "$body" >> "$BODIES_LOG"
  echo "https://github.com/x/y/issues/$issue#issuecomment-$id"
  exit 0
fi

if [[ "$1" == "pr" && "$2" == "review" ]]; then
  echo "PR_REVIEW:$*" >> "$GH_LOG"
  exit 0
fi

if [[ "$1" == "workflow" && "$2" == "run" ]]; then
  echo "DISPATCH:$*" >> "$GH_LOG"
  exit 0
fi

if [[ "$1" == "api" ]]; then
  url="$2"
  case "$url" in
    */comments/*/reactions)
      echo "REACTION:posted" >> "$GH_LOG"
      exit 0
      ;;
    */check-runs/*)
      body_json=$(cat)
      conclusion=$(printf '%s' "$body_json" | jq -r '.conclusion // empty' 2>/dev/null)
      echo "CHECKRUN_PATCH:conclusion=$conclusion" >> "$GH_LOG"
      echo '{"id":1}'
      exit 0
      ;;
    */issues/comments/*)
      cid="${url##*/}"
      newbody="" prev=""
      for a in "$@"; do
        [[ "$prev" == "-f" && "$a" == body=* ]] && newbody="${a#body=}"
        prev="$a"
      done
      tmp=$(mktemp)
      jq --arg id "$cid" --arg body "$newbody" \
        'map(if (.id | tostring) == $id then .body = $body | .updated_at = "t1" else . end)' \
        "$COMMENTS_STORE" > "$tmp" && mv "$tmp" "$COMMENTS_STORE"
      echo "UPDATE_COMMENT:$cid" >> "$GH_LOG"
      printf '%s\n---\n' "$newbody" >> "$BODIES_LOG"
      exit 0
      ;;
    */issues/*/comments)
      cat "$COMMENTS_STORE"
      exit 0
      ;;
  esac
  exit 0
fi

exit 0
SHIM
chmod +x "$SCRATCH/bin/gh"

# run_post [KEY=VAL ...] — runs reviewer/post.sh as a real subprocess against
# the scratch AUTODUCKS_ROOT and gh shim, own RUNNER_TEMP per call.
run_post() {
  local rc=0
  local runner_temp="$SCRATCH/runnertemp-$RANDOM"
  mkdir -p "$runner_temp"
  ( env "$@" \
      PATH="$SCRATCH/bin:$PATH" \
      GH_LOG="$GH_LOG" \
      BODIES_LOG="$BODIES_LOG" \
      COMMENTS_STORE="$COMMENTS_STORE" \
      NEXT_ID_FILE="$NEXT_ID_FILE" \
      AUTODUCKS_ROOT="$CONFIG_ROOT" \
      RUNNER_TEMP="$runner_temp" \
      GITHUB_ACTIONS=true \
      GH_TOKEN=t \
      GITHUB_TOKEN=t \
      REPO="$REPO_NAME" \
      JOB_STATUS=success \
      bash "$POST_SH" > "$SCRATCH/stdout.log" 2> "$SCRATCH/stderr.log" ) || rc=$?
  return $rc
}

reset_run() {
  : > "$GH_LOG"
  : > "$BODIES_LOG"
  echo '[]' > "$COMMENTS_STORE"
  echo 1000 > "$NEXT_ID_FILE"
  rm -f /tmp/review.md /tmp/review-verdict /tmp/work-summary.md
  rm -f /tmp/autoducks-status-comment-id.500 /tmp/autoducks-status-comment-id.77
}

seed_marker() { # feature pr iteration max
  jq -n --arg f "$1" --arg p "$2" --arg it "$3" --arg mx "$4" \
    '[{id: 900, author: "github-actions[bot]",
       body: ("<!-- autoducks:review-loop: feature=" + $f + " pr=" + $p + " iteration=" + $it + " max=" + $mx + " -->"),
       created_at: "t0", updated_at: "t0"}]' > "$COMMENTS_STORE"
}

# =============================================================================
# 1. Default-on: no review.auto_rework in config (defaults true) →
#    request-changes dispatches autoducks-rework.yml and advances the marker
# =============================================================================
echo "── default-on (auto_rework unset): request-changes dispatches + increments ──"
reset_run
write_config '{}'
echo "review body" > /tmp/review.md
echo "request-changes" > /tmp/review-verdict
RC=0
run_post ISSUE_NUM=500 RUN_ID=999 COMMENT_ID=42 COMMENTER=bob PR_NUM=77 FEATURE_NUM=500 \
  REVIEW_TARGETS_CSV="500,77" || RC=$?

[[ "$RC" -eq 0 ]] \
  && pass "exits 0" \
  || fail "expected exit 0, got rc=$RC: $(tail -5 "$SCRATCH/stderr.log")"

if grep -q '^DISPATCH:workflow run autoducks-rework.yml' "$GH_LOG" && grep -q -- '-f pr_number=77' "$GH_LOG"; then
  pass "autoducks-rework.yml dispatched for PR #77"
else
  fail "rework dispatch missing/wrong: $(cat "$GH_LOG")"
fi

if [[ "$(jq -r '.[] | select(.body | contains("feature=500 pr=77")) | .body' "$COMMENTS_STORE")" == *"iteration=1"* ]]; then
  pass "review-loop marker advances to iteration=1"
else
  fail "marker not advanced: $(cat "$COMMENTS_STORE")"
fi

if grep -qF '🔁 Auto-rework round 1/3 dispatched.' "$BODIES_LOG"; then
  pass "status comment carries the auto-rework footer"
else
  fail "auto-rework footer missing: $(cat "$BODIES_LOG")"
fi

echo ""

# =============================================================================
# 2. At the max-iterations cap: posts the handoff + max-iterations note,
#    dispatches nothing
# =============================================================================
echo "── at max iterations: handoff note posted, no dispatch ──"
reset_run
write_config '{}'
seed_marker 500 77 3 3
echo "review body" > /tmp/review.md
echo "request-changes" > /tmp/review-verdict
RC=0
run_post ISSUE_NUM=500 RUN_ID=999 COMMENT_ID=42 COMMENTER=bob PR_NUM=77 FEATURE_NUM=500 \
  REVIEW_TARGETS_CSV="500,77" || RC=$?

[[ "$RC" -eq 0 ]] \
  && pass "exits 0" \
  || fail "expected exit 0, got rc=$RC: $(tail -5 "$SCRATCH/stderr.log")"

if grep -q '^DISPATCH:' "$GH_LOG"; then
  fail "rework dispatched despite being at the max-iterations cap: $(cat "$GH_LOG")"
else
  pass "no rework dispatch at the cap"
fi

if grep -qF '⚠️ Reached max review iterations (3) — stopping automatic rework.' "$BODIES_LOG"; then
  pass "status comment carries the max-iterations handoff note"
else
  fail "max-iterations note missing: $(cat "$BODIES_LOG")"
fi

if grep -qF "$(printf '/rework')" "$BODIES_LOG"; then
  pass "status comment still offers the human /rework command"
else
  fail "human /rework handoff missing: $(cat "$BODIES_LOG")"
fi

if [[ "$(jq -r '.[] | select(.body | contains("feature=500 pr=77")) | .body' "$COMMENTS_STORE")" == *"iteration=3"* ]]; then
  pass "review-loop marker stays at iteration=3 (not advanced past the cap)"
else
  fail "marker unexpectedly changed: $(cat "$COMMENTS_STORE")"
fi

echo ""

# =============================================================================
# 3. auto_rework:false — restores the human-handoff message, no dispatch
# =============================================================================
echo "── auto_rework:false override: human handoff restored, no dispatch ──"
reset_run
write_config '{"auto_rework": false}'
echo "review body" > /tmp/review.md
echo "request-changes" > /tmp/review-verdict
RC=0
run_post ISSUE_NUM=500 RUN_ID=999 COMMENT_ID=42 COMMENTER=bob PR_NUM=77 FEATURE_NUM=500 \
  REVIEW_TARGETS_CSV="500,77" || RC=$?

[[ "$RC" -eq 0 ]] \
  && pass "exits 0" \
  || fail "expected exit 0, got rc=$RC: $(tail -5 "$SCRATCH/stderr.log")"

if grep -q '^DISPATCH:' "$GH_LOG"; then
  fail "rework dispatched despite auto_rework:false: $(cat "$GH_LOG")"
else
  pass "no rework dispatch when auto_rework:false"
fi

if grep -qF 'Auto-rework round' "$BODIES_LOG" || grep -qF 'Reached max review iterations' "$BODIES_LOG"; then
  fail "auto-rework footer leaked despite auto_rework:false: $(cat "$BODIES_LOG")"
else
  pass "no auto-rework footer in the status comment"
fi

if grep -qF "$(printf '/rework')" "$BODIES_LOG" && grep -qF "$(printf '/defer')" "$BODIES_LOG"; then
  pass "human handoff (rework or defer) restored in the status comment"
else
  fail "human handoff missing: $(cat "$BODIES_LOG")"
fi

echo ""

# =============================================================================
# 4. Duplicate ready_for_review / re-trigger for the same PR_HEAD_SHA: the
#    second run must not double-dispatch or double-increment the marker
#    (Idempotency constraint, Finding #2 of ggondim's PR #1038 review).
# =============================================================================
echo "── duplicate event, same PR_HEAD_SHA: second run is a no-op ──"
reset_run
write_config '{}'
echo "review body" > /tmp/review.md
echo "request-changes" > /tmp/review-verdict
RC=0
run_post ISSUE_NUM=500 RUN_ID=999 COMMENT_ID=42 COMMENTER=bob PR_NUM=77 FEATURE_NUM=500 \
  REVIEW_TARGETS_CSV="500,77" PR_HEAD_SHA=deadbeef || RC=$?
[[ "$RC" -eq 0 ]] \
  && pass "first run exits 0" \
  || fail "expected exit 0 on first run, got rc=$RC: $(tail -5 "$SCRATCH/stderr.log")"

echo "review body" > /tmp/review.md
echo "request-changes" > /tmp/review-verdict
RC=0
run_post ISSUE_NUM=500 RUN_ID=999 COMMENT_ID=42 COMMENTER=bob PR_NUM=77 FEATURE_NUM=500 \
  REVIEW_TARGETS_CSV="500,77" PR_HEAD_SHA=deadbeef || RC=$?
[[ "$RC" -eq 0 ]] \
  && pass "second (duplicate) run exits 0" \
  || fail "expected exit 0 on second run, got rc=$RC: $(tail -5 "$SCRATCH/stderr.log")"

DISPATCH_COUNT=$(grep -c '^DISPATCH:workflow run autoducks-rework.yml' "$GH_LOG" || true)
if [[ "$DISPATCH_COUNT" -eq 1 ]]; then
  pass "autoducks-rework.yml dispatched exactly once across both runs"
else
  fail "expected exactly 1 dispatch, got $DISPATCH_COUNT: $(cat "$GH_LOG")"
fi

MARKER_COUNT=$(jq '[.[] | select(.body | contains("feature=500 pr=77"))] | length' "$COMMENTS_STORE")
if [[ "$MARKER_COUNT" -eq 1 ]]; then
  pass "still exactly one review-loop marker comment (edited in place, not duplicated)"
else
  fail "expected 1 marker comment, got $MARKER_COUNT: $(cat "$COMMENTS_STORE")"
fi

if [[ "$(jq -r '.[] | select(.body | contains("feature=500 pr=77")) | .body' "$COMMENTS_STORE")" == *"iteration=1"* ]]; then
  pass "marker advanced to iteration=1 only once (not double-incremented to 2)"
else
  fail "marker iteration wrong after duplicate run: $(cat "$COMMENTS_STORE")"
fi

echo ""

# =============================================================================
# 5. A genuinely new round (different PR_HEAD_SHA, e.g. after rework pushed
#    new commits) still advances and dispatches normally — the guard only
#    suppresses an exact-commit repeat, not legitimate subsequent rounds.
# =============================================================================
echo "── new commit, different PR_HEAD_SHA: dispatches and advances normally ──"
reset_run
write_config '{}'
seed_marker 500 77 1 3
echo "review body" > /tmp/review.md
echo "request-changes" > /tmp/review-verdict
RC=0
run_post ISSUE_NUM=500 RUN_ID=999 COMMENT_ID=42 COMMENTER=bob PR_NUM=77 FEATURE_NUM=500 \
  REVIEW_TARGETS_CSV="500,77" PR_HEAD_SHA=newsha123 || RC=$?

[[ "$RC" -eq 0 ]] \
  && pass "exits 0" \
  || fail "expected exit 0, got rc=$RC: $(tail -5 "$SCRATCH/stderr.log")"

if grep -q '^DISPATCH:workflow run autoducks-rework.yml' "$GH_LOG"; then
  pass "rework dispatched for the new commit"
else
  fail "rework not dispatched for a genuinely new round: $(cat "$GH_LOG")"
fi

if [[ "$(jq -r '.[] | select(.body | contains("feature=500 pr=77")) | .body' "$COMMENTS_STORE")" == *"iteration=2"* ]]; then
  pass "marker advances to iteration=2 for the new round"
else
  fail "marker did not advance for the new round: $(cat "$COMMENTS_STORE")"
fi

echo ""
echo "═══ reviewer-auto-rework: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
