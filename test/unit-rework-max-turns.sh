#!/usr/bin/env bash
# Unit test for the error_max_turns branch in .autoducks/agents/rework/post.sh
# (inserted between the /tmp/rework-none.md green-skip block and the
# /tmp/rework-task.md-missing check). A turn-limit cutoff must be reported as
# AUTODUCKS_FAIL_CATEGORY=max_turns — never mislabeled as scope-missing just
# because /tmp/rework-task.md never got written — and must notify_failure
# with the arity-3 form (task issue + feature issue), same as the
# rework-task.md-missing block right after it.
#
# Runs the real rework/post.sh as a subprocess with `gh` shimmed out (same
# technique as test/unit-verb-idempotency.sh) — no network access and no
# mutation of the real repo.
# Run: bash test/unit-rework-max-turns.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

REPO_NAME="acme/widgets"
GH_LOG="$SCRATCH/gh.log"
: > "$GH_LOG"
MOCK_ISSUE_DIR="$SCRATCH/issues"
MOCK_PR_DIR="$SCRATCH/prs"
mkdir -p "$MOCK_ISSUE_DIR" "$MOCK_PR_DIR"

ISSUE_R=500
FEATURE_R=70
RUN_ID_R=999

jq -n '{title: "Add checkout flow", body: "## Problem Statement\n\nShip a working checkout flow.\n", labels: [], author: "alice"}' \
  > "$MOCK_ISSUE_DIR/$FEATURE_R.json"

# ── gh shim ──────────────────────────────────────────────────────────
# rework/post.sh reaches the outside world only through its::*/git::*
# provider functions, which bottom out in `gh`. `gh issue comment` receives
# the comment body directly as an argument (its::comment_issue), so capture
# it verbatim; `gh api ... reactions` records the reaction content.
mkdir -p "$SCRATCH/bin"
cat > "$SCRATCH/bin/gh" <<'SHIM'
#!/usr/bin/env bash
{
  echo "=== gh $* ==="
} >> "$GH_LOG"

case "$1" in
  issue)
    case "$2" in
      view)
        id="$3"
        if [[ -f "$MOCK_ISSUE_DIR/$id.json" ]]; then
          cat "$MOCK_ISSUE_DIR/$id.json"
        else
          echo '{}'
        fi
        ;;
      comment)
        id="$3"
        prev=""
        for arg in "$@"; do
          if [[ "$prev" == "--body" ]]; then
            printf '%s' "$arg" > "$SCRATCH/comment_${id}_$(date +%s%N 2>/dev/null || echo x).txt.tmp"
            printf '%s' "$arg" >> "$SCRATCH/comments_on_${id}.txt"
            printf '\n---\n' >> "$SCRATCH/comments_on_${id}.txt"
          fi
          prev="$arg"
        done
        echo "https://github.com/$REPO_NAME/issues/$id#issuecomment-777"
        ;;
      edit) : ;;
      close) : ;;
    esac
    ;;
  pr)
    case "$2" in
      view)
        id="$3"
        if [[ -f "$MOCK_PR_DIR/$id.json" ]]; then
          cat "$MOCK_PR_DIR/$id.json"
        else
          echo '{}'
        fi
        ;;
      ready) : ;;
    esac
    ;;
  api)
    # gh api --method POST repos/x/y/issues/comments/<id>/reactions -f content=<r>
    for arg in "$@"; do
      case "$arg" in
        content=*) echo "REACTION:${arg#content=}" >> "$SCRATCH/reactions.log" ;;
      esac
    done
    ;;
  *) : ;;
esac
exit 0
SHIM
chmod +x "$SCRATCH/bin/gh"

run_post() {
  local rc=0
  env \
    PATH="$SCRATCH/bin:$PATH" \
    RUNNER_TEMP="$SCRATCH" \
    GITHUB_RUN_ID="max-turns-test" \
    SCRATCH="$SCRATCH" \
    GH_LOG="$GH_LOG" \
    MOCK_ISSUE_DIR="$MOCK_ISSUE_DIR" \
    MOCK_PR_DIR="$MOCK_PR_DIR" \
    REPO_NAME="$REPO_NAME" \
    GITHUB_ACTIONS=true \
    GH_TOKEN=t \
    REPO="$REPO_NAME" \
    ISSUE_NUM="$ISSUE_R" \
    RUN_ID="$RUN_ID_R" \
    COMMENT_ID=1 \
    COMMENTER=carol \
    PR_NUM=500 \
    FEATURE_NUM="$FEATURE_R" \
    LLM_ERROR_SUBTYPE="error_max_turns" \
    MAX_TURNS=200 \
    bash "$REPO_ROOT/.autoducks/agents/rework/post.sh" \
      > "$SCRATCH/stdout.log" 2> "$SCRATCH/stderr.log" || rc=$?
  return $rc
}

# Ensure /tmp/rework-task.md and /tmp/rework-none.md are absent — the
# error_max_turns branch must fire before the scope-missing check even
# considers them.
rm -f /tmp/rework-task.md /tmp/rework-none.md /tmp/autoducks-status-comment-id."$ISSUE_R"

echo "── error_max_turns: no /tmp/rework-task.md, feature present ──"
RC=0
run_post || RC=$?

[[ "$RC" -eq 1 ]] \
  && pass "post.sh exits 1" \
  || fail "expected exit 1, got $RC: $(tail -5 "$SCRATCH/stderr.log")"

if [[ -f "$SCRATCH/comments_on_${ISSUE_R}.txt" ]] && grep -qF '`max_turns`' "$SCRATCH/comments_on_${ISSUE_R}.txt"; then
  pass "task-issue comment reports category \`max_turns\`"
else
  fail "task-issue comment missing \`max_turns\` category: $(cat "$SCRATCH/comments_on_${ISSUE_R}.txt" 2>/dev/null || echo none)"
fi

if [[ -f "$SCRATCH/comments_on_${ISSUE_R}.txt" ]] && grep -qF '`scope-missing`' "$SCRATCH/comments_on_${ISSUE_R}.txt"; then
  fail "task-issue comment wrongly reports \`scope-missing\` for a turn-limit cutoff"
else
  pass "task-issue comment never reports \`scope-missing\`"
fi

if [[ -f "$SCRATCH/comments_on_${FEATURE_R}.txt" ]] && grep -qF "Task #$ISSUE_R failed" "$SCRATCH/comments_on_${FEATURE_R}.txt"; then
  pass "arity-3 notify_failure also comments on the feature #$FEATURE_R"
else
  fail "expected a 'Task #$ISSUE_R failed' comment on feature #$FEATURE_R: $(cat "$SCRATCH/comments_on_${FEATURE_R}.txt" 2>/dev/null || echo none)"
fi

if grep -qF 'REACTION:confused' "$SCRATCH/reactions.log" 2>/dev/null; then
  pass "reacted confused to the triggering comment"
else
  fail "expected a confused reaction: $(cat "$SCRATCH/reactions.log" 2>/dev/null || echo none)"
fi

echo ""
echo "── rework-none.md green-skip path is unaffected by the new branch ──"
rm -f /tmp/rework-task.md
echo "Feedback already addressed upstream." > /tmp/rework-none.md
: > "$GH_LOG"
rm -f "$SCRATCH"/comments_on_*.txt "$SCRATCH/reactions.log"
RC=0
run_post || RC=$?
rm -f /tmp/rework-none.md

[[ "$RC" -eq 0 ]] \
  && pass "rework-none.md green-skip still exits 0" \
  || fail "expected exit 0 for the green-skip path, got $RC: $(tail -5 "$SCRATCH/stderr.log")"

if [[ -f "$SCRATCH/comments_on_${ISSUE_R}.txt" ]] && grep -qF '`max_turns`' "$SCRATCH/comments_on_${ISSUE_R}.txt"; then
  fail "green-skip path incorrectly went through the max_turns failure branch"
else
  pass "green-skip path does not touch the max_turns branch"
fi

echo ""
echo "── LLM_SKIPPED path is unaffected by the new branch ──"
: > "$GH_LOG"
rm -f "$SCRATCH"/comments_on_*.txt "$SCRATCH/reactions.log"
RC=0
env \
  PATH="$SCRATCH/bin:$PATH" \
  RUNNER_TEMP="$SCRATCH" \
  GITHUB_RUN_ID="max-turns-test" \
  SCRATCH="$SCRATCH" \
  GH_LOG="$GH_LOG" \
  MOCK_ISSUE_DIR="$MOCK_ISSUE_DIR" \
  MOCK_PR_DIR="$MOCK_PR_DIR" \
  REPO_NAME="$REPO_NAME" \
  GITHUB_ACTIONS=true \
  GH_TOKEN=t \
  REPO="$REPO_NAME" \
  ISSUE_NUM="$ISSUE_R" \
  RUN_ID="$RUN_ID_R" \
  COMMENT_ID=1 \
  COMMENTER=carol \
  PR_NUM=500 \
  FEATURE_NUM="$FEATURE_R" \
  LLM_SKIPPED=true \
  LLM_ERROR_SUBTYPE="error_max_turns" \
  bash "$REPO_ROOT/.autoducks/agents/rework/post.sh" \
    > "$SCRATCH/stdout.log" 2> "$SCRATCH/stderr.log" || RC=$?

[[ "$RC" -eq 0 ]] \
  && pass "LLM_SKIPPED still short-circuits to exit 0 even if LLM_ERROR_SUBTYPE is set" \
  || fail "expected exit 0 for LLM_SKIPPED, got $RC: $(tail -5 "$SCRATCH/stderr.log")"

if [[ -f "$SCRATCH/comments_on_${ISSUE_R}.txt" ]] && grep -qF '`max_turns`' "$SCRATCH/comments_on_${ISSUE_R}.txt"; then
  fail "LLM_SKIPPED path incorrectly went through the max_turns failure branch"
else
  pass "LLM_SKIPPED path does not touch the max_turns branch"
fi

echo ""
echo "═══ rework-max-turns: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
