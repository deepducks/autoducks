#!/usr/bin/env bash
# Integration tests for the Architect's delivery-phase guard and its
# strip-on-re-run behavior (.autoducks/agents/architect/pre.sh + post.sh,
# run end-to-end against a mocked `gh` CLI — the same shim convention used by
# test/unit-engineer-dor.sh).
# Run: bash test/unit-architect-guard.sh
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

# Every /tmp marker the Architect's pre.sh/post.sh pair reads or writes —
# cleaned before and after every scenario so runs don't bleed into each other.
clean_tmp() {
  rm -f /tmp/autoducks-pre-failed /tmp/autoducks-status-comment-id \
        /tmp/architect-strip-tactical.flag /tmp/architect-dropped-tasks.txt \
        /tmp/design-spec.md /tmp/design-body.md /tmp/issue-request.md /tmp/issue-body-raw.md \
        /tmp/steering-prompt.md /tmp/design-zone-discard.md /tmp/tactical-zone-discard.md \
        /tmp/issue-type
}

run_pre() { # $1 = issue json file
  export GH_LOG="$SCRATCH/gh.log"
  : > "$GH_LOG"
  export MOCK_ISSUE_FILE="$1"
  RC=0
  (
    PATH="$SCRATCH/bin:$PATH" \
    GITHUB_ACTIONS=true \
    ISSUE_NUM=10 REPO=x/y RUN_ID=999 COMMENT_ID=555 COMMENTER=alice \
    RUNNER_TEMP="$SCRATCH" GITHUB_RUN_ID=archtest \
    GITHUB_OUTPUT="$SCRATCH/gh_output" \
    GH_TOKEN=t \
    bash "$REPO_ROOT/.autoducks/agents/architect/pre.sh"
  ) >/dev/null 2>&1 || RC=$?
}

run_post() { # $1 = auto_chain (optional)
  RC=0
  (
    PATH="$SCRATCH/bin:$PATH" \
    GITHUB_ACTIONS=true \
    ISSUE_NUM=10 REPO=x/y RUN_ID=999 COMMENT_ID=555 COMMENTER=alice \
    RUNNER_TEMP="$SCRATCH" GITHUB_RUN_ID=archtest \
    AUTO_CHAIN="${1:-}" \
    GH_TOKEN=t \
    bash "$REPO_ROOT/.autoducks/agents/architect/post.sh"
  ) >/dev/null 2>&1 || RC=$?
}

# ---------------------------------------------------------------------------
echo "── Architect guard: delivery already started ──"
clean_tmp
cat > "$SCRATCH/issue-locked.json" <<'JSON'
{"title": "Add search", "body": "designed body", "labels": ["Design:done", "Tactics:done", "Work:coding"], "author": "alice"}
JSON
run_pre "$SCRATCH/issue-locked.json"
[[ "$RC" -eq 0 ]] && pass "pre exits 0 on the lock path" || fail "rc=$RC"
grep -q 'gh issue comment.*Design is locked' "$GH_LOG" \
  && pass "lock comment posted" || fail "no lock comment: $(cat "$GH_LOG")"
COMMENT_CALLS=$(grep -c '^gh issue comment' "$GH_LOG" || true)
[[ "$COMMENT_CALLS" -eq 1 ]] \
  && pass "exactly one comment posted (status_comment::start not reached)" \
  || fail "expected 1 comment call, got $COMMENT_CALLS"
grep -q 'api --method POST repos/x/y/issues/comments/555/reactions.*content=confused' "$GH_LOG" \
  && pass "reacted confused" || fail "no confused reaction: $(cat "$GH_LOG")"
if grep -q '^gh issue edit' "$GH_LOG"; then
  fail "body/labels were mutated: $(grep '^gh issue edit' "$GH_LOG")"
else
  pass "no label/body mutation"
fi
[[ -f "$SCRATCH/autoducks-archtest/pre-failed" ]] \
  && pass "pre-failed marker written for post.sh" || fail "marker missing"
clean_tmp

# ---------------------------------------------------------------------------
echo "── Architect strip: re-run over a Tactics:done multi-task plan ──"
clean_tmp
TACTICAL_BODY=$(cat <<'MD'
## Problem Statement

Some existing design.

<!-- autoducks:tactical:begin -->
## Plan

```yaml
waves:
  - name: Wave 1
    tasks: [101, 102]
```

## Progress

- [ ] #101 Task one `P0`
- [ ] #102 Task two `P0`
<!-- autoducks:tactical:end -->
MD
)
jq -n --arg title "Add search" --arg body "$TACTICAL_BODY" \
  --argjson labels '["Design:done", "Tactics:done"]' --arg author alice \
  '{title: $title, body: $body, labels: $labels, author: $author}' \
  > "$SCRATCH/issue-multi.json"

run_pre "$SCRATCH/issue-multi.json"
[[ "$RC" -eq 0 ]] && pass "pre exits 0 on a discovery-phase re-run" || fail "rc=$RC"
if grep -q 'Design is locked' "$GH_LOG"; then
  fail "guard fired on a discovery-phase issue (no Work:* label, no branch)"
else
  pass "guard did not fire (discovery phase)"
fi
[[ -f /tmp/architect-strip-tactical.flag ]] \
  && pass "strip flag set" || fail "strip flag missing"
[[ "$(tr '\n' ' ' < /tmp/architect-dropped-tasks.txt)" == "101 102 " ]] \
  && pass "both old task numbers captured" || fail "dropped tasks: $(cat /tmp/architect-dropped-tasks.txt)"

# The LLM step runs between pre.sh and post.sh in production; stand in for it.
echo "## Problem Statement

Revised design." > /tmp/design-spec.md

run_post "engineer"
[[ "$RC" -eq 0 ]] && pass "post exits 0" || fail "rc=$RC"
grep -q 'issue edit 10 --repo x/y --body-file /tmp/design-body.md' "$GH_LOG" \
  && pass "design-only body published" || fail "body not published: $(cat "$GH_LOG")"
grep -q '^gh issue close 101 ' "$GH_LOG" \
  && pass "old task #101 closed" || fail "#101 not closed"
grep -q '^gh issue close 102 ' "$GH_LOG" \
  && pass "old task #102 closed" || fail "#102 not closed"
grep -q 'issue edit 10 --repo x/y --remove-label Tactics:done' "$GH_LOG" \
  && pass "Tactics:done removed" || fail "Tactics:done not removed: $(cat "$GH_LOG")"
grep -q '⚠️' "$GH_LOG" && grep -q '#101, #102' "$GH_LOG" \
  && pass "finish comment carries the re-run-engineer warning with both numbers" \
  || fail "warning/numbers missing: $(cat "$GH_LOG")"
grep -q 'workflow run autoducks-engineer.yml --repo x/y -f issue_number=10' "$GH_LOG" \
  && pass "chain::dispatch_next reached the end of post.sh" \
  || fail "chain dispatch not reached: $(cat "$GH_LOG")"
clean_tmp

# ---------------------------------------------------------------------------
echo "── Architect strip: re-run over a single-task plan ──"
clean_tmp
TACTICAL_BODY_SINGLE=$(cat <<'MD'
## Problem Statement

Some existing design.

<!-- autoducks:tactical:begin -->
## Plan

```yaml
waves:
  - name: Wave 1
    tasks: [201]
```

## Progress

- [ ] #201 Only task `P0`
<!-- autoducks:tactical:end -->
MD
)
jq -n --arg title "Add search" --arg body "$TACTICAL_BODY_SINGLE" \
  --argjson labels '["Design:done", "Tactics:done"]' --arg author alice \
  '{title: $title, body: $body, labels: $labels, author: $author}' \
  > "$SCRATCH/issue-single.json"

run_pre "$SCRATCH/issue-single.json"
[[ "$RC" -eq 0 ]] && pass "pre exits 0 on a single-task discovery-phase re-run" || fail "rc=$RC"
[[ -f /tmp/architect-strip-tactical.flag ]] \
  && pass "strip flag set (single-task)" || fail "strip flag missing"
[[ "$(tr -d '[:space:]' < /tmp/architect-dropped-tasks.txt)" == "201" ]] \
  && pass "single old task number captured" || fail "dropped tasks: $(cat /tmp/architect-dropped-tasks.txt)"

echo "## Problem Statement

Revised design, single task." > /tmp/design-spec.md

run_post "engineer"
[[ "$RC" -eq 0 ]] && pass "post exits 0 (single-task)" || fail "rc=$RC"
CLOSE_CALLS=$(grep -c '^gh issue close' "$GH_LOG" || true)
[[ "$CLOSE_CALLS" -eq 1 ]] \
  && pass "closes at most one child task" || fail "expected 1 close call, got $CLOSE_CALLS"
grep -q '^gh issue close 201 ' "$GH_LOG" \
  && pass "old task #201 closed" || fail "#201 not closed"
grep -q 'issue edit 10 --repo x/y --remove-label Tactics:done' "$GH_LOG" \
  && pass "Tactics:done removed (single-task)" || fail "Tactics:done not removed"
grep -q '⚠️' "$GH_LOG" \
  && pass "finish comment still carries the re-run-engineer warning" \
  || fail "warning missing: $(cat "$GH_LOG")"
grep -q 'workflow run autoducks-engineer.yml --repo x/y -f issue_number=10' "$GH_LOG" \
  && pass "chain::dispatch_next reached the end of post.sh (single-task)" \
  || fail "chain dispatch not reached"
clean_tmp

echo ""
echo "═══ architect-guard: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
