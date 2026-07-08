#!/usr/bin/env bash
# Idempotency coverage for the `rework` and `defer` agents — the same
# invariants test/unit-idempotency.sh locks for architect/engineer/developer:
#
#   1. Rework: a second `/rework` on a PR with an already-open rework
#      sub-issue updates that sub-issue in place instead of minting a
#      second one (exactly one rework sub-issue survives two invocations).
#      Also covers the single-task fast-path → wave-2 promotion: the first
#      `/rework` on a feature with no tactical plan yet must preserve the
#      completed original task and produce a valid two-wave `## Progress`
#      checklist rather than wiping it.
#   2. Defer: a second `/defer` for the same (feature, PR) pair updates the
#      existing deferral issue in place instead of minting a second one
#      (exactly one deferral issue survives two invocations).
#
# Runs the real agent pre.sh/post.sh scripts as subprocesses with `gh`
# shimmed out (same technique as test/unit-idempotency.sh) — no network
# access and no mutation of the real repo.
#
# Run: bash test/unit-verb-idempotency.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

# shellcheck source=/dev/null
source "$REPO_ROOT/.autoducks/core/orchestration/parse-waves.sh"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

REPO_NAME="acme/widgets"
GH_LOG="$SCRATCH/gh.log"
: > "$GH_LOG"
MOCK_ISSUE_DIR="$SCRATCH/issues"
MOCK_PR_DIR="$SCRATCH/prs"
GH_CAPTURE_DIR="$SCRATCH/captured"
mkdir -p "$MOCK_ISSUE_DIR" "$MOCK_PR_DIR" "$GH_CAPTURE_DIR"

MOCK_SUB_ISSUES_FILE="$SCRATCH/sub_issues.json"
echo '[]' > "$MOCK_SUB_ISSUES_FILE"
MOCK_SEARCH_MATCH=""

# ── Shared gh shim ────────────────────────────────────────────────────
# rework/defer reach the outside world only through its::*/git::* provider
# functions, which all bottom out in `gh`. Putting a fake `gh` first on PATH
# lets the real pre.sh/post.sh run unmodified against canned fixtures instead
# of hitting GitHub. Issue creation is stateful (persists into
# MOCK_ISSUE_DIR) so a second round's lookups see what the first round wrote.
mkdir -p "$SCRATCH/bin"
cat > "$SCRATCH/bin/gh" <<'SHIM'
#!/usr/bin/env bash
{
  echo "=== gh $* ==="
} >> "$GH_LOG"

# Nested on $1 then $2 (NOT a flat "$1 $2" case) — `gh api <path> ...` has a
# dynamic $2 (the path), so a flat "api" pattern would never match it.
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
        echo "https://github.com/x/y/issues/$3#issuecomment-777"
        ;;
      edit)
        id="$3"
        prev=""
        for arg in "$@"; do
          if [[ "$prev" == "--body-file" ]]; then
            cp "$arg" "$GH_CAPTURE_DIR/$id.md"
          fi
          prev="$arg"
        done
        ;;
      close) : ;;
      list)
        # Idempotency search used by defer/pre.sh; test-controlled match.
        echo "${MOCK_SEARCH_MATCH:-}"
        ;;
    esac
    ;;
  label)
    : # label create
    ;;
  pr)
    case "$2" in
      list)
        state="open"
        prev=""
        for arg in "$@"; do
          [[ "$prev" == "--state" ]] && state="$arg"
          prev="$arg"
        done
        case "$state" in
          open)   cat "${MOCK_OPEN_PRS_FILE:-/dev/null}" 2>/dev/null || echo "[]" ;;
          merged) cat "${MOCK_MERGED_PRS_FILE:-/dev/null}" 2>/dev/null || echo "[]" ;;
          *)      echo "[]" ;;
        esac
        ;;
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
    method="GET"
    path=""
    prevflag=""
    for arg in "${@:2}"; do
      if [[ "$prevflag" == "--method" ]]; then
        method="$arg"; prevflag=""; continue
      fi
      case "$arg" in
        --method) prevflag="--method"; continue ;;
        --*)      continue ;;
        *)        [[ -z "$path" ]] && path="$arg" ;;
      esac
    done
    if [[ "$method" == "POST" && "$path" == repos/*/issues ]]; then
      # Simulate creating a brand-new issue (rework sub-issue or deferral
      # issue) and persist it into MOCK_ISSUE_DIR so a later `issue view`
      # (e.g. the next round's idempotency scan) sees real content instead
      # of an empty fixture.
      payload="$(cat)"
      counter_file="$SCRATCH/next_issue_num"
      n=$(cat "$counter_file" 2>/dev/null || echo 900)
      n=$((n + 1))
      echo "$n" > "$counter_file"
      echo "$payload" | jq -c '{title: (.title // ""), body: (.body // ""), labels: (.labels // []), author: "bot"}' \
        > "$MOCK_ISSUE_DIR/$n.json"
      echo "{\"number\": $n, \"id\": $((n + 900000))}"
    elif [[ "$path" == repos/*/issues/*/sub_issues ]]; then
      cat "${MOCK_SUB_ISSUES_FILE:-/dev/null}" 2>/dev/null || echo "[]"
    elif [[ "$path" == repos/*/issues/*/comments ]]; then
      echo "[]"
    elif [[ "$path" == repos/*/pulls/*/comments ]]; then
      echo "[]"
    elif [[ "$path" == repos/*/issues/[0-9]* ]]; then
      num="${path##*/}"
      echo "{\"id\": $((num + 900000))}"
    elif [[ "$path" == *comments* ]]; then
      echo "[]"
    fi
    ;;
  *) : ;;
esac
exit 0
SHIM
chmod +x "$SCRATCH/bin/gh"

# run_step <script> [KEY=VAL ...]
# Runs an agent pre.sh/post.sh as a real subprocess (its own `set -e`, its
# own ERR trap) with the shim first on PATH. Prints stderr and returns the
# script's exit code so callers can assert on it.
run_step() {
  local script="$1"; shift
  local rc=0
  env "$@" \
    PATH="$SCRATCH/bin:$PATH" \
    SCRATCH="$SCRATCH" \
    GH_LOG="$GH_LOG" \
    MOCK_ISSUE_DIR="$MOCK_ISSUE_DIR" \
    MOCK_PR_DIR="$MOCK_PR_DIR" \
    MOCK_SUB_ISSUES_FILE="${MOCK_SUB_ISSUES_FILE:-}" \
    MOCK_SEARCH_MATCH="${MOCK_SEARCH_MATCH:-}" \
    GH_CAPTURE_DIR="$GH_CAPTURE_DIR" \
    GITHUB_ACTIONS=true \
    GH_TOKEN=t \
    REPO="$REPO_NAME" \
    bash "$script" > "$SCRATCH/stdout.log" 2> "$SCRATCH/stderr.log" || rc=$?
  return $rc
}

reset_tmp() {
  rm -f /tmp/autoducks-pre-failed /tmp/autoducks-status-comment-id /tmp/design-plan.md \
    /tmp/rework-context.md /tmp/steering-prompt.md /tmp/rework-none.md /tmp/rework-task.md \
    /tmp/rework-task.jsonl /tmp/parse-error.md /tmp/rework-task-final.jsonl /tmp/link-outcomes.tsv \
    /tmp/rework-feature-body-raw.md /tmp/rework-design-zone.md /tmp/rework-tactical-current.md \
    /tmp/rework-tactical-step1.md /tmp/rework-tactical-zone-new.md /tmp/rework-feature-body-new.md \
    /tmp/defer-reviews.json /tmp/defer-comments.json /tmp/defer-context.md /tmp/defer-none.md \
    /tmp/defer-issue.md /tmp/defer-issue-final.md
}

# =============================================================================
# 1. Rework — idempotency + single-task fast-path → wave-2 promotion
# =============================================================================
echo "── Rework: single-task promotion, then idempotent re-run ──"

REWORK_PRE="$REPO_ROOT/.autoducks/agents/rework/pre.sh"
REWORK_POST="$REPO_ROOT/.autoducks/agents/rework/post.sh"

FEATURE_R=70
PR_R=500

jq -n '{title: "Add checkout flow", body: "## Problem Statement\n\nShip a working checkout flow for the store.\n", labels: ["Design:done"], author: "alice"}' \
  > "$MOCK_ISSUE_DIR/$FEATURE_R.json"
jq -n --arg body "Implements checkout validation.

Closes #$FEATURE_R" \
  '{number: 500, title: "Add checkout validation", body: $body, state: "OPEN", isDraft: false, headRefName: "feature/70-checkout", baseRefName: "main", reviews: []}' \
  > "$MOCK_PR_DIR/$PR_R.json"

run_rework_round() {
  # run_rework_round <fake_llm_task_md>
  local llm_task="$1"
  reset_tmp

  local env_file="$SCRATCH/rework_github_env"
  : > "$env_file"

  run_step "$REWORK_PRE" ISSUE_NUM="$PR_R" RUN_ID=1 COMMENT_ID=1 COMMENTER=carol IS_PR=true \
      GITHUB_ENV="$env_file" \
    || { fail "rework pre.sh failed (rc=$?): $(tail -5 "$SCRATCH/stderr.log")"; return 1; }

  local pr_num pr_head feature_num rework_task_num
  pr_num=$(grep '^PR_NUM=' "$env_file" | tail -1 | cut -d= -f2-)
  pr_head=$(grep '^PR_HEAD=' "$env_file" | tail -1 | cut -d= -f2-)
  feature_num=$(grep '^FEATURE_NUM=' "$env_file" | tail -1 | cut -d= -f2-)
  rework_task_num=$(grep '^REWORK_TASK_NUM=' "$env_file" | tail -1 | cut -d= -f2-)

  printf '%s' "$llm_task" > /tmp/rework-task.md

  AUTODUCKS_SUB_ISSUES_STATUS=unavailable \
    run_step "$REWORK_POST" ISSUE_NUM="$PR_R" RUN_ID=1 COMMENT_ID=1 COMMENTER=carol \
      PR_NUM="$pr_num" PR_HEAD="$pr_head" FEATURE_NUM="$feature_num" REWORK_TASK_NUM="$rework_task_num" \
    || { fail "rework post.sh failed (rc=$?): $(tail -5 "$SCRATCH/stderr.log")"; return 1; }
}

REWORK_TASK_1='## Tasks

### T1 — Fix checkout validation bug

**Summary:** Address reviewer feedback about checkout validation.

**Tasks:**
- [ ] fix validation logic

**Acceptance Criteria:**
- [ ] validation passes for edge cases
'

: > "$GH_LOG"
run_rework_round "$REWORK_TASK_1"

R1_CREATE_COUNT=$(grep -cE 'repos/[^ ]*/issues["'"'"']? --method POST' "$GH_LOG" || true)
[[ "$R1_CREATE_COUNT" -eq 1 ]] \
  && pass "round 1: exactly one issue-create call (new rework sub-issue minted)" \
  || fail "round 1: expected exactly one issue-create call, got $R1_CREATE_COUNT"

NEW_TASK_NUM=$(cut -f1 /tmp/link-outcomes.tsv 2>/dev/null | head -1)
if [[ "$NEW_TASK_NUM" =~ ^[0-9]+$ ]]; then
  pass "round 1: rework sub-issue #$NEW_TASK_NUM created"
else
  fail "round 1: could not recover new rework task number from link-outcomes.tsv"
fi

FEATURE_BODY_R1="$GH_CAPTURE_DIR/$FEATURE_R.md"
if [[ -f "$FEATURE_BODY_R1" ]]; then
  pass "round 1: feature #$FEATURE_R body was updated"
else
  fail "round 1: feature #$FEATURE_R body was never edited"
fi

if grep -q "^- \[x\] #$FEATURE_R " "$FEATURE_BODY_R1" 2>/dev/null; then
  pass "round 1: original single task #$FEATURE_R survives as a completed checklist item"
else
  fail "round 1: completed original task #$FEATURE_R missing from ## Progress: $(grep '^- \[' "$FEATURE_BODY_R1" 2>/dev/null || echo none)"
fi

if grep -q "^- \[ \] #$NEW_TASK_NUM " "$FEATURE_BODY_R1" 2>/dev/null; then
  pass "round 1: new rework task #$NEW_TASK_NUM appears as a pending checklist item"
else
  fail "round 1: rework task #$NEW_TASK_NUM missing from ## Progress"
fi

if grep -q "Ship a working checkout flow for the store" "$FEATURE_BODY_R1" 2>/dev/null; then
  pass "round 1: original design content preserved"
else
  fail "round 1: original design content was wiped"
fi

WAVES_OUT=$(parse_waves "$(cat "$FEATURE_BODY_R1" 2>/dev/null)" 2>/dev/null || true)
if grep -q "TASK|0|$FEATURE_R" <<< "$WAVES_OUT" && grep -q "TASK|1|$NEW_TASK_NUM" <<< "$WAVES_OUT"; then
  pass "round 1: promoted body parses as a valid 2-wave plan (Wave 1: #$FEATURE_R, Rework: #$NEW_TASK_NUM)"
else
  fail "round 1: promoted body did not parse into the expected 2-wave plan: $WAVES_OUT"
fi

echo ""

# Second /rework: pre.sh's idempotency guard must find the sub-issue created
# above (its::list_sub_issues is driven by MOCK_SUB_ISSUES_FILE, since linking
# is disabled via AUTODUCKS_SUB_ISSUES_STATUS=unavailable in round 1).
jq -n --arg n "$NEW_TASK_NUM" '[{number: ($n|tonumber), title: "rework", state: "open"}]' \
  > "$MOCK_SUB_ISSUES_FILE"

REWORK_TASK_2='## Tasks

### T1 — Fix checkout validation bug (round 2 wording)

**Summary:** Reviewer asked for additional validation coverage.

**Tasks:**
- [ ] fix validation logic
- [ ] add regression test

**Acceptance Criteria:**
- [ ] validation passes for edge cases
- [ ] regression test added
'

: > "$GH_LOG"
run_rework_round "$REWORK_TASK_2"

R2_CREATE_COUNT=$(grep -cE 'repos/[^ ]*/issues["'"'"']? --method POST' "$GH_LOG" || true)
[[ "$R2_CREATE_COUNT" -eq 0 ]] \
  && pass "round 2: no new issue-create call (existing sub-issue reused)" \
  || fail "round 2: expected zero issue-create calls, got $R2_CREATE_COUNT"

if grep -qE "issue edit $NEW_TASK_NUM --repo $REPO_NAME .*--body-file" "$GH_LOG"; then
  pass "round 2: existing rework sub-issue #$NEW_TASK_NUM updated in place"
else
  fail "round 2: expected sub-issue #$NEW_TASK_NUM to be edited in place"
fi

if grep -qE "issue edit $FEATURE_R --repo $REPO_NAME --body-file" "$GH_LOG"; then
  fail "round 2: feature #$FEATURE_R body was re-touched (Progress checklist should be left alone)"
else
  pass "round 2: feature #$FEATURE_R body left untouched (already part of a wave)"
fi

echo ""

# =============================================================================
# 2. Defer — idempotency
# =============================================================================
echo "── Defer: idempotent re-run reuses the deferral issue ──"

DEFER_PRE="$REPO_ROOT/.autoducks/agents/defer/pre.sh"
DEFER_POST="$REPO_ROOT/.autoducks/agents/defer/post.sh"

FEATURE_D=80
PR_D=600

jq -n '{title: "Add search endpoint", body: "## Problem Statement\n\nAdd a search endpoint to the API.\n", labels: ["Design:done"], author: "alice"}' \
  > "$MOCK_ISSUE_DIR/$FEATURE_D.json"
jq -n --arg body "Implements the search endpoint.

Closes #$FEATURE_D" \
  '{number: 600, title: "Add search endpoint", body: $body, state: "OPEN", isDraft: false, headRefName: "feature/80-search", baseRefName: "main",
    reviews: [{author: {login: "carol"}, state: "CHANGES_REQUESTED", body: "Please add input validation.", submittedAt: "2026-07-01T00:00:00Z"}]}' \
  > "$MOCK_PR_DIR/$PR_D.json"

run_defer_round() {
  # run_defer_round <fake_llm_issue_md>
  local llm_issue="$1"
  reset_tmp

  local env_file="$SCRATCH/defer_github_env"
  : > "$env_file"

  run_step "$DEFER_PRE" ISSUE_NUM="$PR_D" RUN_ID=1 COMMENT_ID=1 COMMENTER=carol IS_PR=true \
      GITHUB_ENV="$env_file" \
    || { fail "defer pre.sh failed (rc=$?): $(tail -5 "$SCRATCH/stderr.log")"; return 1; }

  local pr_num feature_num existing_defer_num
  pr_num=$(grep '^PR_NUM=' "$env_file" | tail -1 | cut -d= -f2-)
  feature_num=$(grep '^FEATURE_NUM=' "$env_file" | tail -1 | cut -d= -f2-)
  existing_defer_num=$(grep '^EXISTING_DEFER_NUM=' "$env_file" | tail -1 | cut -d= -f2-)

  printf '%s' "$llm_issue" > /tmp/defer-issue.md

  run_step "$DEFER_POST" ISSUE_NUM="$PR_D" RUN_ID=1 COMMENT_ID=1 COMMENTER=carol \
      PR_NUM="$pr_num" FEATURE_NUM="$feature_num" EXISTING_DEFER_NUM="$existing_defer_num" \
    || { fail "defer post.sh failed (rc=$?): $(tail -5 "$SCRATCH/stderr.log")"; return 1; }
}

DEFER_ISSUE_1='## Summary

Deferred feedback: improve error messaging on invalid checkout state.

## Details

- Carol requested clearer error messages when checkout state is invalid.
'

: > "$GH_LOG"
run_defer_round "$DEFER_ISSUE_1"

D1_CREATE_COUNT=$(grep -cE 'repos/[^ ]*/issues["'"'"']? --method POST' "$GH_LOG" || true)
[[ "$D1_CREATE_COUNT" -eq 1 ]] \
  && pass "round 1: exactly one issue-create call (new deferral issue minted)" \
  || fail "round 1: expected exactly one issue-create call, got $D1_CREATE_COUNT"

DEFER_ISSUE_NUM=$(grep -oP 'Deferred \d+ review comments? to #\K[0-9]+' "$GH_LOG" | head -1)
if [[ "$DEFER_ISSUE_NUM" =~ ^[0-9]+$ ]]; then
  pass "round 1: deferral issue #$DEFER_ISSUE_NUM created"
else
  fail "round 1: could not recover deferral issue number from the status comment"
fi

if [[ -f "$MOCK_ISSUE_DIR/$DEFER_ISSUE_NUM.json" ]] \
    && grep -qF "<!-- autoducks:deferred-from: pr=$PR_D feature=$FEATURE_D -->" "$MOCK_ISSUE_DIR/$DEFER_ISSUE_NUM.json"; then
  pass "round 1: deferral issue carries the idempotency marker"
else
  fail "round 1: deferral issue missing the idempotency marker"
fi

echo ""

# Second /defer for the same (feature, PR): pre.sh's search-based idempotency
# guard must find the issue created above.
MOCK_SEARCH_MATCH="$DEFER_ISSUE_NUM"

DEFER_ISSUE_2='## Summary

Deferred feedback: improve error messaging on invalid checkout state (updated).

## Details

- Carol requested clearer error messages; also flagged a duplicate submit issue.
'

: > "$GH_LOG"
run_defer_round "$DEFER_ISSUE_2"

D2_CREATE_COUNT=$(grep -cE 'repos/[^ ]*/issues["'"'"']? --method POST' "$GH_LOG" || true)
[[ "$D2_CREATE_COUNT" -eq 0 ]] \
  && pass "round 2: no new issue-create call (existing deferral issue reused)" \
  || fail "round 2: expected zero issue-create calls, got $D2_CREATE_COUNT"

if grep -qE "issue edit $DEFER_ISSUE_NUM --repo $REPO_NAME --body-file" "$GH_LOG"; then
  pass "round 2: existing deferral issue #$DEFER_ISSUE_NUM updated in place"
else
  fail "round 2: expected deferral issue #$DEFER_ISSUE_NUM to be edited in place"
fi

DEFER_ISSUE_NUM_R2=$(grep -oP 'Deferred \d+ review comments? to #\K[0-9]+' "$GH_LOG" | head -1)
[[ "$DEFER_ISSUE_NUM_R2" == "$DEFER_ISSUE_NUM" ]] \
  && pass "round 2: status comment still points at the single deferral issue #$DEFER_ISSUE_NUM" \
  || fail "round 2: status comment pointed at #$DEFER_ISSUE_NUM_R2, expected #$DEFER_ISSUE_NUM"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "═══ verb idempotency: $PASS passed, $FAIL failed ═══"
[[ "$FAIL" -eq 0 ]] || exit 1
